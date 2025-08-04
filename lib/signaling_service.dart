import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';

/// Handles WebRTC signaling logic and manages peer connections, room logic, and streams
/// Keeps UI code clean and testable.
class WebRTCSignaling {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  String? _roomId;
  User? user;

  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;
  final void Function()? onRemoteStream;

  WebRTCSignaling({
    required this.localRenderer,
    required this.remoteRenderer,
    required this.onRemoteStream,
    this.user,
  });

  /// Open device camera and microphone
  Future<void> openUserMedia() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {'facingMode': 'user'},
    });
    localRenderer.srcObject = stream;
    _localStream = stream;
    debugPrint('Local media stream opened (service)');
  }

  /// Join or create a signaling room for one-to-one call
  Future<void> createOrJoinRoom(String roomId) async {
    _roomId = roomId;
    final roomRef = FirebaseFirestore.instance.collection('rooms').doc(roomId);
    final roomSnapshot = await roomRef.get();

    Map<String, dynamic> config = {'mandatory': {}, 'optional': []};
    _peerConnection = await createPeerConnection({
      'iceServers': [{
        'url': 'stun:stun.l.google.com:19302',
      }]
    }, config);

    _peerConnection!.onIceCandidate = (c) async {
      debugPrint('Sending ICE: $c');
      if (c.candidate != null) {
        roomRef.collection(user!.uid == roomSnapshot.data()?['callerId']
            ? 'calleeCandidates'
            : 'callerCandidates').add(c.toMap());
      }
    };
    _peerConnection!.onTrack = (event) {
      debugPrint('Remote media stream received (service)');
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
        onRemoteStream?.call();
      }
    };
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    if (!roomSnapshot.exists) {
      // Create new (the host)
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      await roomRef.set({'offer': offer.toMap(), 'callerId': user!.uid});
      roomRef.snapshots().listen((snapshot) async {
        var data = snapshot.data();
        if (data?['answer'] != null && _peerConnection?.getRemoteDescription() == null) {
          await _peerConnection!.setRemoteDescription(RTCSessionDescription(data!['answer']['sdp'], data['answer']['type']));
          debugPrint('Set remote answer (service)');
        }
      });
      roomRef.collection('calleeCandidates').snapshots().listen((snapshot) {
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data();
            if (data != null) {
              debugPrint('Adding ICE from callee (service)');
              _peerConnection!.addCandidate(RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']));
            }
          }
        }
      });
    } else {
      // Join as the other peer
      final data = roomSnapshot.data();
      await _peerConnection!.setRemoteDescription(RTCSessionDescription(data?['offer']['sdp'], data?['offer']['type']));
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      await roomRef.update({'answer': answer.toMap(), 'calleeId': user!.uid});

      roomRef.collection('callerCandidates').snapshots().listen((snapshot) {
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data();
            if (data != null) {
              debugPrint('Adding ICE from caller (service)');
              _peerConnection!.addCandidate(RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']));
            }
          }
        }
      });
    }
  }

  Future<void> hangup() async {
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    await _localStream?.dispose();
    await _peerConnection?.close();
    debugPrint('Call ended (service)');
    _roomId = null;
  }
}

