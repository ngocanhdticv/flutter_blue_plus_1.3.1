// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of flutter_blue_plus;

class FlutterBluePlus {
  final MethodChannel _channel =
      const MethodChannel('flutter_blue_plus/methods');
  final EventChannel _stateChannel =
      const EventChannel('flutter_blue_plus/state');
  final StreamController<MethodCall> _methodStreamController =
      StreamController.broadcast(); // ignore: close_sinks
  // Stream<MethodCall> get _methodStream => _methodStreamController
  //     .stream; // Used internally to dispatch methods from platform.
  static final _StreamController<bool> _isScanning = _StreamController(initialValue: false);
  static final _StreamController<List<ScanResult>> _scanResultsList = _StreamController(initialValue: []);
  static _BufferStream<BmScanResponse>? _scanResponseBuffer;
  static Timer? _scanTimeout;
  static final StreamController<MethodCall> _methodStream = StreamController.broadcast();
  static bool _initialized = false;

  // native platform channel
  static const MethodChannel _methods = MethodChannel('flutter_blue_plus/methods');

  /// Cached broadcast stream for FlutterBlue.state events
  /// Caching this stream allows for more than one listener to subscribe
  /// and unsubscribe apart from each other,
  /// while allowing events to still be sent to others that are subscribed
  // Stream<BluetoothState>? _stateStream;

  /// Singleton boilerplate
  FlutterBluePlus._() {
    _channel.setMethodCallHandler((MethodCall call) async {
      _methodStreamController.add(call);
    });

    setLogLevel(logLevel);
  }

  static final FlutterBluePlus _instance = FlutterBluePlus._();
  static FlutterBluePlus get instance => _instance;

  /// Log level of the instance, default is all messages (debug).
  // LogLevel _logLevel = LogLevel.debug;
  // LogLevel get logLevel => _logLevel;

  static LogLevel _logLevel = LogLevel.debug;
  static bool _logColor = true;
  static LogLevel get logLevel => _logLevel;

  /// Checks whether the device supports Bluetooth
  Future<bool> get isAvailable =>
      _channel.invokeMethod('isAvailable').then<bool>((d) => d);

  /// Return the friendly Bluetooth name of the local Bluetooth adapter
  Future<String> get name =>
      _channel.invokeMethod('name').then<String>((d) => d);

  /// Checks if Bluetooth functionality is turned on
  Future<bool> get isOn => _channel.invokeMethod('isOn').then<bool>((d) => d);

  /// Tries to turn on Bluetooth (Android only),
  ///
  /// Returns true if bluetooth is being turned on.
  /// You have to listen for a stateChange to ON to ensure bluetooth is already running
  ///
  /// Returns false if an error occured or bluetooth is already running
  ///
  Future<bool> turnOn() {
    return _channel.invokeMethod('turnOn').then<bool>((d) => d);
  }

  /// Tries to turn off Bluetooth (Android only),
  ///
  /// Returns true if bluetooth is being turned off.
  /// You have to listen for a stateChange to OFF to ensure bluetooth is turned off
  ///
  /// Returns false if an error occured
  ///
  Future<bool> turnOff() {
    return _channel.invokeMethod('turnOff').then<bool>((d) => d);
  }

  // final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);
  static Stream<bool> get isScanning => _isScanning.stream;

  // final BehaviorSubject<List<ScanResult>> _scanResults =
  //     BehaviorSubject.seeded([]);

  /// Returns a stream that is a list of [ScanResult] results while a scan is in progress.
  ///
  /// The list emitted is all the scanned results as of the last initiated scan. When a scan is
  /// first started, an empty list is emitted. The returned stream is never closed.
  ///
  /// One use for [scanResults] is as the stream in a StreamBuilder to display the
  /// results of a scan in real time while the scan is in progress.
  // Stream<List<ScanResult>> get scanResults => _scanResults.stream;

  // final PublishSubject _stopScanPill = PublishSubject();

  /// Gets the current state of the Bluetooth module
  Stream<BluetoothAdapterState> get state async* {
    BluetoothAdapterState initialState = await _invokeMethod('getAdapterState')
        .then((buffer) => BmBluetoothAdapterState.fromMap(buffer))
        .then((s) => _bmToBluetoothAdapterState(s.adapterState));

    yield initialState;

    Stream<BluetoothAdapterState> responseStream = FlutterBluePlus._methodStream.stream
        .where((m) => m.method == "OnAdapterStateChanged")
        .map((m) => m.arguments)
        .map((buffer) => BmBluetoothAdapterState.fromMap(buffer))
        .map((s) => _bmToBluetoothAdapterState(s.adapterState));

    yield* responseStream;
  }

  /// Retrieve a list of connected devices
  Future<List<BluetoothDevice>> get connectedDevices {
    return _invokeMethod('getConnectedSystemDevices')
        .then((buffer) => BmConnectedDevicesResponse.fromMap(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  /// Retrieve a list of bonded devices (Android only)
  Future<List<BluetoothDevice>> get bondedDevices {
    return _invokeMethod('getBondedDevices')
        .then((buffer) => BmConnectedDevicesResponse.fromMap(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  /// Starts a scan for Bluetooth Low Energy devices and returns a stream
  /// of the [ScanResult] results as they are received.
  ///    - throws an exception if scanning is already in progress
  ///    - [timeout] calls stopScan after a specified duration
  ///    - [androidUsesFineLocation] requests ACCESS_FINE_LOCATION permission at runtime regardless
  ///    of Android version. On Android 11 and below (Sdk < 31), this permission is required
  ///    and therefore we will always request it. Your AndroidManifest.xml must match.
  static Stream<ScanResult> scan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<String> macAddresses = const [],
    Duration? timeout,
    bool allowDuplicates = false,
    bool androidUsesFineLocation = false,
  }) async* {
    try {
      var settings = BmScanSettings(
          serviceUuids: withServices,
          macAddresses: macAddresses,
          allowDuplicates: allowDuplicates,
          androidScanMode: scanMode.value,
          androidUsesFineLocation: androidUsesFineLocation);

      if (_isScanning.value == true) {
        throw FlutterBluePlusException('scan', -1, 'Another scan is already in progress.');
      }

      // push to isScanning stream
      // we must do this early on to prevent duplicate scans
      _isScanning.add(true);

      // Clear scan results list
      _scanResultsList.add(<ScanResult>[]);

      Stream<BmScanResponse> responseStream = FlutterBluePlus._methodStream.stream
          .where((m) => m.method == "OnScanResponse")
          .map((m) => m.arguments)
          .map((buffer) => BmScanResponse.fromMap(buffer))
          .takeWhile((element) => _isScanning.value)
          .doOnDone(stopScan);

      // Start listening now, before invokeMethod, to ensure we don't miss any results
      _scanResponseBuffer = _BufferStream.listen(responseStream);

      // Start timer *after* stream is being listened to, to make sure the
      // timeout does not fire before _scanResponseBuffer is set
      if (timeout != null) {
        _scanTimeout = Timer(timeout, () {
          _scanResponseBuffer?.close();
          _isScanning.add(false);
          _invokeMethod('stopScan');
        });
      }

      await _invokeMethod('startScan', settings.toMap());

      await for (BmScanResponse response in _scanResponseBuffer!.stream) {
        // failure?
        if (response.failed != null) {
          throw FlutterBluePlusException("scan", response.failed!.errorCode, response.failed!.errorString);
        }

        // no result?
        if (response.result == null) {
          continue;
        }

        ScanResult item = ScanResult.fromProto(response.result!);

        // make new list while considering duplicates
        List<ScanResult> list = _addOrUpdate(_scanResultsList.value, item);

        // update list
        _scanResultsList.add(list);

        yield item;
      }
    } finally {
      // cleanup
      _scanResponseBuffer?.close();
      _isScanning.add(false);
    }
  }

  /// Start a scan
  ///  - future completes when the scan is done.
  ///  - To observe the results live, listen to the [scanResults] stream.
  ///  - call [stopScan] to complete the returned future, or set [timeout]
  ///  - see [scan] documentation for more details
  static Future startScan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<String> macAddresses = const [],
    Duration? timeout,
    bool allowDuplicates = false,
    bool androidUsesFineLocation = false,
  }) async {
    await scan(
        scanMode: scanMode,
        withServices: withServices,
        macAddresses: macAddresses,
        timeout: timeout,
        allowDuplicates: allowDuplicates,
        androidUsesFineLocation: androidUsesFineLocation)
        .drain();
    return _scanResultsList.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  static Future stopScan() async {
    await _invokeMethod('stopScan');
    _scanResponseBuffer?.close();
    _scanTimeout?.cancel();
    _isScanning.add(false);
  }

  /// The list of connected peripherals can include those that are connected
  /// by other apps and that will need to be connected locally using the
  /// device.connect() method before they can be used.
//  Stream<List<BluetoothDevice>> connectedDevices({
//    List<Guid> withServices = const [],
//  }) =>
//      throw UnimplementedError();

  /// Sets the internal FlutterBlue log level
  static void setLogLevel(LogLevel level, {color = true}) async {
    await _invokeMethod('setLogLevel', level.index);
    _logLevel = level;
    _logColor = color;
  }

  // invoke a platform method
  static Future<dynamic> _invokeMethod(String method, [dynamic arguments]) async {
    // initialize handler
    if (_initialized == false) {
      // set handler
      _methods.setMethodCallHandler((MethodCall call) async {
        // log result
        if (logLevel == LogLevel.verbose) {
          String func = '[[ ${call.method} ]]';
          String result = call.arguments.toString();
          func = _logColor ? _black(func) : func;
          result = _logColor ? _brown(result) : result;
          print("[FBP] $func result: $result");
        }
        _methodStream.add(call);
      });

      // avoid recursion: must set this
      // before we call setLogLevel
      _initialized = true;

      setLogLevel(logLevel);
    }

    // log args
    if (logLevel == LogLevel.verbose) {
      String func = '<$method>';
      String args = arguments.toString();
      func = _logColor ? _black(func) : func;
      args = _logColor ? _magenta(args) : args;
      print("[FBP] $func args: $args");
    }

    // invoke
    dynamic obj = await _methods.invokeMethod(method, arguments);

    // log result
    if (logLevel == LogLevel.verbose) {
      String func = '<$method>';
      String result = obj.toString();
      func = _logColor ? _black(func) : func;
      result = _logColor ? _brown(result) : result;
      print("[FBP] $func result: $result");
    }

    return obj;
  }

  // void _log(LogLevel level, String message) {
  //   if (level.index <= _logLevel.index) {
  //     if (kDebugMode) {
  //       print(message);
  //     }
  //   }
  // }
}

/// Log levels for FlutterBlue
enum LogLevel {
  none, //0
  error, // 1
  warning, // 2
  info, // 3
  debug, // 4
  verbose, //5
}

/// State of the bluetooth adapter.
enum BluetoothAdapterState { unknown, unavailable, unauthorized, turningOn, on, turningOff, off }

class ScanMode {
  const ScanMode(this.value);
  static const lowPower = ScanMode(0);
  static const balanced = ScanMode(1);
  static const lowLatency = ScanMode(2);
  static const opportunistic = ScanMode(-1);
  final int value;
}

class DeviceIdentifier {
  final String str;
  const DeviceIdentifier(this.str);

  @Deprecated('Use str instead')
  String get id => str;

  @override
  String toString() => str;

  @override
  int get hashCode => str.hashCode;

  @override
  bool operator ==(other) => other is DeviceIdentifier && _compareAsciiLowerCase(str, other.str) == 0;
}

// class ScanResult {
//   ScanResult.fromProto(protos.ScanResult p)
//       : device = BluetoothDevice.fromProto(p.device),
//         advertisementData = AdvertisementData.fromProto(p.advertisementData),
//         rssi = p.rssi,
//         timeStamp = DateTime.now();
//
//   final BluetoothDevice device;
//   final AdvertisementData advertisementData;
//   final int rssi;
//   final DateTime timeStamp;
//
//   @override
//   bool operator ==(Object other) =>
//       identical(this, other) ||
//       other is ScanResult &&
//           runtimeType == other.runtimeType &&
//           device == other.device;
//
//   @override
//   int get hashCode => device.hashCode;
//
//   @override
//   String toString() {
//     return 'ScanResult{device: $device, advertisementData: $advertisementData, rssi: $rssi, timeStamp: $timeStamp}';
//   }
// }

class AdvertisementData {
  final String localName;
  final int? txPowerLevel;
  final bool connectable;
  final Map<int, List<int>> manufacturerData;
  final Map<String, List<int>> serviceData;
  // Note: we use strings and not Guids because advertisement UUIDs can
  // be 32-bit UUIDs, 64-bit, etc i.e. "FE56"
  final List<String> serviceUuids;

  AdvertisementData({
    required this.localName,
    required this.txPowerLevel,
    required this.connectable,
    required this.manufacturerData,
    required this.serviceData,
    required this.serviceUuids,
  });

  AdvertisementData.fromProto(BmAdvertisementData p)
      : localName = p.localName ?? "",
        txPowerLevel = p.txPowerLevel,
        connectable = p.connectable,
        manufacturerData = p.manufacturerData,
        serviceData = p.serviceData,
        serviceUuids = p.serviceUuids;

  @override
  String toString() {
    return 'AdvertisementData{'
        'localName: $localName, '
        'txPowerLevel: $txPowerLevel, '
        'connectable: $connectable, '
        'manufacturerData: $manufacturerData, '
        'serviceData: $serviceData, '
        'serviceUuids: $serviceUuids'
        '}';
  }
}

class FlutterBluePlusException implements Exception {
  final String errorName;
  final int? errorCode;
  final String? errorString;

  FlutterBluePlusException(this.errorName, this.errorCode, this.errorString);

  @override
  String toString() {
    return 'FlutterBluePlusException: name:$errorName errorCode:$errorCode, errorString:$errorString';
  }
}

class ScanResult {
  final BluetoothDevice device;
  final AdvertisementData advertisementData;
  final int rssi;
  final DateTime timeStamp;

  ScanResult({
    required this.device,
    required this.advertisementData,
    required this.rssi,
    required this.timeStamp,
  });

  ScanResult.fromProto(BmScanResult p)
      : device = BluetoothDevice.fromProto(p.device),
        advertisementData = AdvertisementData.fromProto(p.advertisementData),
        rssi = p.rssi,
        timeStamp = DateTime.now();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && runtimeType == other.runtimeType && device == other.device;

  @override
  int get hashCode => device.hashCode;

  @override
  String toString() {
    return 'ScanResult{'
        'device: $device, '
        'advertisementData: $advertisementData, '
        'rssi: $rssi, '
        'timeStamp: $timeStamp'
        '}';
  }
}

