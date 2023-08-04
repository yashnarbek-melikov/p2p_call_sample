import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:connectycube_sdk/connectycube_sdk.dart';

import 'src/login_screen.dart';
import 'src/managers/call_manager.dart';
import 'src/utils/configs.dart' as config;
import 'src/utils/pref_util.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  log('[main]');
  Firebase.initializeApp(
      options: FirebaseOptions(
          apiKey: 'AIzaSyCDTgrvuguN7wSN01jyRp19KZ7kRDB7-Hg',
          appId: '1:1074274251645:android:bafe52ea19db941c7f5214',
          messagingSenderId: '1074274251645',
          projectId: 'p2p-call-b15ad'));
  runApp(App());
}

class App extends StatefulWidget {
  @override
  State<StatefulWidget> createState() {
    return _AppState();
  }
}

class _AppState extends State<App> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.green,
      ),
      home: Builder(
        builder: (context) {
          CallManager.instance.init(context);

          return LoginScreen();
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    initConnectycube();
  }
}

initConnectycube() {
  init(
    config.APP_ID,
    config.AUTH_KEY,
    config.AUTH_SECRET,
    onSessionRestore: () {
      return SharedPrefs.getUser().then((savedUser) {
        return createSession(savedUser);
      });
    },
  );
}

initConnectycubeContextLess() {
  CubeSettings.instance.applicationId = config.APP_ID;
  CubeSettings.instance.authorizationKey = config.AUTH_KEY;
  CubeSettings.instance.authorizationSecret = config.AUTH_SECRET;
  CubeSettings.instance.onSessionRestore = () {
    return SharedPrefs.getUser().then((savedUser) {
      return createSession(savedUser);
    });
  };
}
