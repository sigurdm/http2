// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO: Take priorities into account.
// TODO: Properly fragment large data frames, so they are not taking up too much
// bandwidth.
library http2.src.flowcontrol.connection_flow_controller;

import 'dart:async';
import 'dart:collection';

import '../../transport.dart';

import '../error_handler.dart';
import '../frames/frames.dart';

import 'stream_queues.dart';
import 'queue_messages.dart';
import 'window_handler.dart';
import '../frames/frames.dart';

/// The last place before messages coming from the application get encoded and
/// send as [Frame]s.
///
/// It will convert [Message]s from higher layers and send them via [Frame]s.
///
/// - It will queue messages until the connection-level flow control window
///   allows sending the message and the underlying [StreamSink] is not
///   buffering.
/// - It will use a [FrameWriter] to write a new frame to the connection.
class ConnectionMessageQueueOut extends Object with TerminatableMixin {
  /// The handler which will be used for increasing the connection-level flow
  /// control window.
  final OutgoingConnectionWindowHandler _connectionWindow;

  /// The buffered [Message]s which are to be delivered to the remote peer.
  final Queue<Message> _messages = new Queue<Message>();

  /// The [FrameWriter] used for writing Headers/Data/PushPromise frames.
  final FrameWriter _frameWriter;

  ConnectionMessageQueueOut(this._connectionWindow, this._frameWriter) {
    _frameWriter.bufferIndicator.bufferEmptyEvents.listen((_) {
      _trySendMessages();
    });
    _connectionWindow.positiveWindow.bufferEmptyEvents.listen((_) {
      _trySendMessages();
    });
  }

  /// The number of pending messages which haven't been written to the wire.
  int get pendingMessages => _messages.length;

  /// Enqueues a new [Message] which should be delivered to the remote peer.
  void enqueueMessage(Message message) {
    if (!wasTerminated) {
      _messages.addLast(message);
      _trySendMessages();
    }
  }

  void onTerminated(error) {
    _messages.clear();
  }

  void _trySendMessages() {
    if (!wasTerminated) {
      _trySendMessage();

      // If we have more messages and we can send them, we'll run them
      // using `Timer.run()` to let other things get in-between.
      if (_messages.length > 0 &&
          !_connectionWindow.positiveWindow.wouldBuffer) {
        // TODO: If all the frame writer methods would return an integer of the
        // number of bytes written, we could just say, we loop here until 10kb
        // and after words, we'll make `Timer.run()`.
        Timer.run(_trySendMessages);
      }
    }
  }

  void _trySendMessage() {
    if (!_frameWriter.bufferIndicator.wouldBuffer && _messages.length > 0) {
      Message message = _messages.first;
      if (message is HeadersMessage) {
        _messages.removeFirst();
        _frameWriter.writeHeadersFrame(
            message.streamId, message.headers, endStream: message.endStream);
      } else if (message is PushPromiseMessage) {
        _messages.removeFirst();
        _frameWriter.writePushPromiseFrame(
            message.streamId, message.promisedStreamId, message.headers);
      } else if (message is DataMessage) {
        _messages.removeFirst();

        if (_connectionWindow.peerWindowSize >= message.bytes.length) {
          _connectionWindow.decreaseWindow(message.bytes.length);
          _frameWriter.writeDataFrame(
              message.streamId, message.bytes, endStream: message.endStream);
        } else {
          // NOTE: We need to fragment the DataMessage.
          // TODO: Do not fragment if the number of bytes we can send is too low
          int len = _connectionWindow.peerWindowSize;
          var head = viewOrSublist(message.bytes, 0, len);
          var tail = viewOrSublist(
              message.bytes, len, message.bytes.length - len);

          _connectionWindow.decreaseWindow(head.length);
          _frameWriter.writeDataFrame(message.streamId, head, endStream: false);

          var tailMessage =
              new DataMessage(message.streamId, tail, message.endStream);
          _messages.addFirst(tailMessage);
        }
      } else {
        throw new StateError(
            'Unexpected message in queue: ${message.runtimeType}');
      }
    }
  }
}

/// The first place an incoming stream message gets delivered to.
///
/// The [ConnectionMessageQueueIn] will be given [Frame]s which were sent to
/// any stream on this connection.
///
/// - It will extract the necessary data from the [Frame] and store it in a new
///   [Message] object.
/// - It will multiplex the created [Message]es to a stream-specific
///   [StreamMessageQueueIn].
/// - If the [StreamMessageQueueIn] cannot accept more data, the data will be
///   buffered until it can.
/// - [DataMessage]s which have been successfully delivered to a stream-specific
///   [StreamMessageQueueIn] will increase the flow control window for the
///   connection.
///
/// Incoming [DataFrame]s will decrease the flow control window the peer has
/// available.
class ConnectionMessageQueueIn extends Object with TerminatableMixin {
  /// The handler which will be used for increasing the connection-level flow
  /// control window.
  final IncomingWindowHandler _windowUpdateHandler;

  /// A mapping from stream-id to the corresponding stream-specific
  /// [StreamMessageQueueIn].
  final Map<int, StreamMessageQueueIn> _stream2messageQueue = {};

  /// A buffer for [Message]s which cannot be received by their
  /// [StreamMessageQueueIn].
  final Map<int, Queue<Message>> _stream2pendingMessages = {};

  /// The number of pending messages which haven't been delivered
  /// to the stream-specific queue. (for debugging purposes)
  int _count = 0;

  ConnectionMessageQueueIn(this._windowUpdateHandler);

  void onTerminated(error) {
    // NOTE: The higher level will be shutdown first, so all streams
    // should have been removed at this point.
    assert(_stream2messageQueue.isEmpty);
    assert(_stream2pendingMessages.isEmpty);
  }

  /// The number of pending messages which haven't been delivered
  /// to the stream-specific queue. (for debugging purposes)
  int get pendingMessages => _count;

  /// Registers a stream specific [StreamMessageQueueIn] for a new stream id.
  void insertNewStreamMessageQueue(int streamId, StreamMessageQueueIn mq) {
    if (_stream2messageQueue.containsKey(streamId)) {
      throw new ArgumentError(
          'Cannot register a SteramMessageQueueIn for the same streamId '
          'multiple times');
    }

    var pendingMessages = new Queue<Message>();
    _stream2pendingMessages[streamId] = pendingMessages;
    _stream2messageQueue[streamId] = mq;

    mq.bufferIndicator.bufferEmptyEvents.listen((_) {
      _tryDispatch(streamId, mq, pendingMessages);
    });
  }

  /// Removes a stream id and its message queue from this connection-level
  /// message queue.
  void removeStreamMessageQueue(int streamId) {
    _stream2pendingMessages.remove(streamId);
    _stream2messageQueue.remove(streamId);
  }

  /// Processes an incoming [DataFrame] which is addressed to a specific stream.
  void processDataFrame(DataFrame frame) {
    var streamId = frame.header.streamId;
    var message =
        new DataMessage(streamId, frame.bytes, frame.hasEndStreamFlag);

    _windowUpdateHandler.gotData(message.bytes.length);
    _addMessage(streamId, message);
  }

  /// If a [DataFrame] will be ignored, this method will take the minimal
  /// action necessary.
  void processIgnoredDataFrame(DataFrame frame) {
    _windowUpdateHandler.gotData(frame.bytes.length);
  }

  /// Processes an incoming [HeadersFrame] which is addressed to a specific
  /// stream.
  void processHeadersFrame(HeadersFrame frame) {
    var streamId = frame.header.streamId;
    var message = new HeadersMessage(
        streamId, frame.decodedHeaders, frame.hasEndStreamFlag);
    // NOTE: Header frames do not affect flow control - only data frames do.
    _addMessage(streamId, message);
  }

  /// Processes an incoming [PushPromiseFrame] which is addressed to a specific
  /// stream.
  void processPushPromiseFrame(PushPromiseFrame frame,
                               TransportStream pushedStream) {
    var streamId = frame.header.streamId;
    var message = new PushPromiseMessage(
        streamId, frame.decodedHeaders, frame.promisedStreamId, pushedStream,
        false);
    // NOTE: Header frames do not affect flow control - only data frames do.
    _addMessage(streamId, message);
  }

  void _addMessage(int streamId, Message message) {
    _count++;

    // FIXME: We need to do a runtime check here and
    // raise a protocol error if we cannot find the registered stream.
    var streamMQ = _stream2messageQueue[streamId];
    var pendingMessages = _stream2pendingMessages[streamId];
    pendingMessages.addLast(message);
    _tryDispatch(streamId, streamMQ, pendingMessages);
  }

  void _tryDispatch(int streamId,
                    StreamMessageQueueIn mq,
                    Queue<Message> pendingMessages) {
    int bytesDeliveredToStream = 0;
    while (!mq.bufferIndicator.wouldBuffer && pendingMessages.length > 0) {
      _count--;

      var message = pendingMessages.removeFirst();
      if (message is DataMessage) {
        bytesDeliveredToStream += message.bytes.length;
      }
      mq.enqueueMessage(message);
      if (message.endStream) {
        // FIXME: This should be turned into a check and we should
        // raise a protocol error if we ever get a message on a stream
        // which has been closed.
        assert (pendingMessages.isEmpty);

        _stream2messageQueue.remove(streamId);
        _stream2pendingMessages.remove(streamId);
      }
    }
    if (bytesDeliveredToStream > 0) {
      _windowUpdateHandler.dataProcessed(bytesDeliveredToStream);
    }
  }
}