import 'dart:convert';

import 'package:connectycube_flutter_call_kit/connectycube_flutter_call_kit.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:universal_io/io.dart';

import 'package:connectycube_sdk/connectycube_sdk.dart';

import '../../main.dart';
import '../utils/consts.dart';
import '../utils/pref_util.dart';

class PushNotificationsManager {
  static const TAG = "PushNotificationsManager";

  static PushNotificationsManager? _instance;
  FirebaseMessaging firebaseMessaging = FirebaseMessaging.instance;

  PushNotificationsManager._internal();

  static PushNotificationsManager _getInstance() {
    return _instance ??= PushNotificationsManager._internal();
  }

  factory PushNotificationsManager() => _getInstance();

  BuildContext? applicationContext;

  static PushNotificationsManager get instance => _getInstance();

  init() async {
    ConnectycubeFlutterCallKit.initEventsHandler();

    ConnectycubeFlutterCallKit.onTokenRefreshed = (token) {
      log('[onTokenRefresh] VoIP token: $token', TAG);
      subscribe(token);
    };

    ConnectycubeFlutterCallKit.getToken().then((token) {
      log('[getToken] VoIP token: $token', TAG);
      if (token != null) {
        subscribe(token);
      }
    });

    ConnectycubeFlutterCallKit.onCallRejectedWhenTerminated =
        onCallRejectedWhenTerminated;
  }

  subscribe(String token) async {
    log('[subscribe] token: $token', PushNotificationsManager.TAG);

    var savedToken = await SharedPrefs.getSubscriptionToken();
    if (token == savedToken) {
      log('[subscribe] skip subscription for same token',
          PushNotificationsManager.TAG);
      return;
    }

    CreateSubscriptionParameters parameters = CreateSubscriptionParameters();
    parameters.pushToken = token;

    parameters.environment =
        kReleaseMode ? CubeEnvironment.PRODUCTION : CubeEnvironment.DEVELOPMENT;

    if (Platform.isAndroid) {
      parameters.channel = NotificationsChannels.GCM;
      parameters.platform = CubePlatform.ANDROID;
    } else if (Platform.isIOS) {
      parameters.channel = NotificationsChannels.APNS_VOIP;
      parameters.platform = CubePlatform.IOS;
    }

    var deviceInfoPlugin = DeviceInfoPlugin();

    var deviceId;

    if (kIsWeb) {
      var webBrowserInfo = await deviceInfoPlugin.webBrowserInfo;
      deviceId = base64Encode(utf8.encode(webBrowserInfo.userAgent ?? ''));
    } else if (Platform.isAndroid) {
      var androidInfo = await deviceInfoPlugin.androidInfo;
      deviceId = androidInfo.id;
    } else if (Platform.isIOS) {
      var iosInfo = await deviceInfoPlugin.iosInfo;
      deviceId = iosInfo.identifierForVendor;
    } else if (Platform.isMacOS) {
      var macOsInfo = await deviceInfoPlugin.macOsInfo;
      deviceId = macOsInfo.computerName;
    }

    parameters.udid = deviceId;

    var packageInfo = await PackageInfo.fromPlatform();
    parameters.bundleIdentifier = packageInfo.packageName;

    createSubscription(parameters.getRequestParameters())
        .then((cubeSubscriptions) {
      log('[subscribe] subscription SUCCESS', PushNotificationsManager.TAG);
      SharedPrefs.saveSubscriptionToken(token);
      cubeSubscriptions.forEach((subscription) {
        if (subscription.device!.clientIdentificationSequence == token) {
          SharedPrefs.saveSubscriptionId(subscription.id!);
        }
      });
    }).catchError((error) {
      log('[subscribe] subscription ERROR: $error',
          PushNotificationsManager.TAG);
    });
  }

  Future<void> unsubscribe() {
    return SharedPrefs.getSubscriptionId().then((subscriptionId) async {
      if (subscriptionId != 0) {
        return deleteSubscription(subscriptionId).then((voidResult) {
          SharedPrefs.saveSubscriptionId(0);
        });
      } else {
        return Future.value();
      }
    }).catchError((onError) {
      log('[unsubscribe] ERROR: $onError', PushNotificationsManager.TAG);
    });
  }
}

@pragma('vm:entry-point')
Future<void> onCallRejectedWhenTerminated(CallEvent callEvent) async {
  print(
      '[PushNotificationsManager][onCallRejectedWhenTerminated] callEvent: $callEvent');

  var currentUser = await SharedPrefs.getUser();
  initConnectycubeContextLess();

  var sendOfflineReject = rejectCall(callEvent.sessionId, {
    ...callEvent.opponentsIds.where((userId) => currentUser!.id != userId),
    callEvent.callerId
  });
  var sendPushAboutReject = sendPushAboutRejectFromKilledState({
    PARAM_CALL_TYPE: callEvent.callType,
    PARAM_SESSION_ID: callEvent.sessionId,
    PARAM_CALLER_ID: callEvent.callerId,
    PARAM_CALLER_NAME: callEvent.callerName,
    PARAM_CALL_OPPONENTS: callEvent.opponentsIds.join(','),
  }, callEvent.callerId);

  return Future.wait([sendOfflineReject, sendPushAboutReject]).then((result) {
    return Future.value();
  });
}

Future<void> sendPushAboutRejectFromKilledState(
  Map<String, dynamic> parameters,
  int callerId,
) {
  CreateEventParams params = CreateEventParams();
  params.parameters = parameters;
  params.parameters['message'] = "Reject call";
  params.parameters[PARAM_SIGNAL_TYPE] = SIGNAL_TYPE_REJECT_CALL;
  // params.parameters[PARAM_IOS_VOIP] = 1;

  params.notificationType = NotificationType.PUSH;
  params.environment =
      kReleaseMode ? CubeEnvironment.PRODUCTION : CubeEnvironment.DEVELOPMENT;
  params.usersIds = [callerId];

  return createEvent(params.getEventForRequest());
}

Future<void> init() async {
  Firebase.initializeApp();
  FirebaseMessaging firebaseMessaging = FirebaseMessaging.instance;
  String? token;

  // request permissions for showing notification in iOS
  firebaseMessaging.requestPermission(alert: true, badge: true, sound: true);

  if (Platform.isAndroid || kIsWeb) {
    token = await firebaseMessaging.getToken();
  } else if (Platform.isIOS || Platform.isMacOS) {
    token = await firebaseMessaging.getAPNSToken();
  }

  if (!isEmpty(token)) {
    subscribe(token ?? '');
  }

  firebaseMessaging.onTokenRefresh.listen((newToken) {
    subscribe(newToken);
  });

  // add listener for foreground push notifications
  FirebaseMessaging.onMessage.listen((remoteMessage) {
    log('[onMessage] message: $remoteMessage');
    showNotification(remoteMessage);
  });

  // set listener for push notifications, which will be received when app in background or killed
  FirebaseMessaging.onBackgroundMessage(onBackgroundMessage);
}

Future<void> onBackgroundMessage(RemoteMessage message) {
  log('[onBackgroundMessage] message: $message');
  showNotification(message);
  return Future.value();
}

showNotification(RemoteMessage message) {
  log('[showNotification] message: ${message.data}',
      PushNotificationsManager.TAG);
  Map<String, dynamic> data = message.data;

  NotificationDetails buildNotificationDetails(
    int? badge,
    String threadIdentifier,
  ) {
    final DarwinNotificationDetails darwinNotificationDetails =
        DarwinNotificationDetails(
      badgeNumber: badge,
      threadIdentifier: threadIdentifier,
    );

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'messages_channel_id',
      'Chat messages',
      channelDescription: 'Chat messages will be received here',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      color: Colors.green,
    );

    return NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: darwinNotificationDetails,
        macOS: darwinNotificationDetails);
  }

  var badge = int.tryParse(data['badge'].toString());
  var threadId = data['ios_thread_id'] ?? data['dialog_id'] ?? 'ios_thread_id';

  FlutterLocalNotificationsPlugin().show(
    6543,
    "Chat sample",
    data['message'].toString(),
    buildNotificationDetails(badge, threadId),
    payload: jsonEncode(data),
  );
}

subscribe(String token) async {
  log('[subscribe] token: $token');

  bool isProduction = bool.fromEnvironment('dart.vm.product');

  CreateSubscriptionParameters parameters = CreateSubscriptionParameters();
  parameters.environment =
      isProduction ? CubeEnvironment.PRODUCTION : CubeEnvironment.DEVELOPMENT;

  if (Platform.isAndroid) {
    parameters.channel = NotificationsChannels.GCM;
    parameters.platform = CubePlatform.ANDROID;
    parameters.bundleIdentifier = "com.connectycube.flutter.chat_sample";
  } else if (Platform.isIOS) {
    parameters.channel = NotificationsChannels.APNS;
    parameters.platform = CubePlatform.IOS;
    parameters.bundleIdentifier = Platform.isIOS
        ? "com.connectycube.flutter.chatSample.app"
        : "com.connectycube.flutter.chatSample.macOS";
  }

  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
  parameters.udid = androidInfo.id;
  parameters.pushToken = token;

  createSubscription(parameters.getRequestParameters())
      .then((cubeSubscription) {})
      .catchError((error) {});
}

unSubscribe() {
  getSubscriptions()
      .then((subscriptionsList) {
        int? subscriptionIdToDelete =
            subscriptionsList[0].id; // or other subscription's id
        return deleteSubscription(
            subscriptionIdToDelete != null ? subscriptionIdToDelete : 0);
      })
      .then((voidResult) {})
      .catchError((error) {});
}
