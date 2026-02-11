import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:system_audio_recorder/system_audio_recorder.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';


// ===== MODE CONSTANTS (EXTENDED WITH AUDIO VISUALIZERS) =====
const int MODE_STATIC = 0;
const int MODE_RAINBOW = 1;
const int MODE_FIRE = 2;
const int MODE_PALETTE = 3;
const int MODE_CYLON = 4;
const int MODE_PACIFICA = 5;
const int MODE_PRIDE = 6;
const int MODE_PLASMA = 7;
const int MODE_AURORA = 8;
const int MODE_MATRIX = 9;
const int MODE_AUDIO_SPECTRUM = 10;    // Frequency bars (bass=red → treble=blue)
const int MODE_AUDIO_WAVE = 11;        // Smooth wave pulsing with energy
const int MODE_AUDIO_ENERGY = 12;      // Overall energy glow with beat detection
const int MODE_AUDIO_PARTICLES = 13;   // Particles explode on beats
const int MODE_AUDIO_RAINBOW_BARS = 14; // Colorful spectrum with gradient bars

extension SystemAudioRecorderSafe on SystemAudioRecorder {
  static Future<void> safeStopRecord() async {
    try {
      // Check if recording is actually active before stopping
      // (Workaround for plugin bug that crashes on rapid stop/start)
      await SystemAudioRecorder.stopRecord();
    } catch (e) {
      debugPrint('Safe stop ignored error: $e');
      // Swallow errors - native plugin often throws during cleanup
    }
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(AudioCaptureTaskHandler());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize audio session early
  final session = await AudioSession.instance;
  await session.configure(AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
    AVAudioSessionCategoryOptions.defaultToSpeaker |
    AVAudioSessionCategoryOptions.mixWithOthers,
    avAudioSessionMode: AVAudioSessionMode.measurement,
    avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
    avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
  ));

  runApp(const EspLedApp());
}

class EspLedApp extends StatelessWidget {
  const EspLedApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP LED Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const SmartConnectionScreen(),
    );
  }
}

// ===== DISCOVERED DEVICE MODEL =====
class DiscoveredDevice {
  final String ip;
  final String status;
  final DateTime timestamp;
  DiscoveredDevice({
    required this.ip,
    required this.status,
    required this.timestamp,
  });
}

// ===== Smart Connection Screen with WiFi scanning =====
class SmartConnectionScreen extends StatefulWidget {
  const SmartConnectionScreen({super.key});
  @override
  State<SmartConnectionScreen> createState() => _SmartConnectionScreenState();
}

class _SmartConnectionScreenState extends State<SmartConnectionScreen> with TickerProviderStateMixin {
  String _status = '🔍 Discovering ESP...';
  bool _isScanning = true;
  bool _showManualSetup = false;
  Timer? _visibilityTimer;
  Timer? _autoReconnectTimer;
  // WiFi scanning
  List<DiscoveredDevice> _discoveredDevices = [];
  bool _isWifiScanning = false;
  String? _currentWifiSSID;
  // Auto-reconnect
  String? _lastKnownIP;
  int _reconnectAttempts = 0;
  static const int MAX_RECONNECT_ATTEMPTS = 3;
  // Animations
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _rotateController;

  @override
  void initState() {
    super.initState();
    // Setup pulse animation for scanning indicator
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    // Setup rotation animation for scanning icon
    _rotateController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _loadLastKnownIP();
    _getCurrentWifiSSID();
    _startDiscovery();
    // Show options after 8 seconds
    _visibilityTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        setState(() => _showManualSetup = true);
      }
    });
  }

  @override
  void dispose() {
    _visibilityTimer?.cancel();
    _autoReconnectTimer?.cancel();
    _pulseController.dispose();
    _rotateController.dispose();
    super.dispose();
  }

  Future<void> _loadLastKnownIP() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ip = prefs.getString('last_known_ip');
      if (ip != null && mounted) {
        setState(() => _lastKnownIP = ip);
      }
    } catch (e) {
      print('Failed to load last known IP: $e');
    }
  }

  Future<void> _saveLastKnownIP(String ip) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_known_ip', ip);
      setState(() => _lastKnownIP = ip);
    } catch (e) {
      print('Failed to save last known IP: $e');
    }
  }

  Future<void> _getCurrentWifiSSID() async {
    try {
      final info = NetworkInfo();
      final wifiName = await info.getWifiName();
      if (mounted) {
        setState(() {
          _currentWifiSSID = wifiName?.replaceAll('"', '');
        });
      }
    } catch (e) {
      print('Failed to get WiFi SSID: $e');
    }
  }

  void _startDiscovery() async {
    setState(() {
      _isScanning = true;
      _status = '🔍 Starting smart discovery...';
      _discoveredDevices.clear();
    });
    // STEP 1: Try last known IP first (auto-reconnect)
    if (_lastKnownIP != null && _reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
      setState(() => _status = '🔄 Trying last known IP: $_lastKnownIP...');
      final result = await _testConnectionWithTimeout(_lastKnownIP!, 2000);
      if (result != null && result != 'AP_MODE') {
        _connectToEsp(result);
        return;
      }
      _reconnectAttempts++;
    }
    // STEP 2: Try .local resolution
    setState(() => _status = '🔍 Trying esp-led.local resolution...');
    final hostnameIp = await _resolveWithTimeout('esp-led.local', 3000);
    if (hostnameIp != null) {
      _connectToEsp(hostnameIp);
      return;
    }
    // STEP 3: Try common alternate hostnames
    final altHostnames = ['espled.local', 'wemos.local', 'lolin.local'];
    for (final hostname in altHostnames) {
      final ip = await _resolveWithTimeout(hostname, 1500);
      if (ip != null) {
        _connectToEsp(ip);
        return;
      }
    }
    // STEP 4: WiFi-aware smart scan
    await _wifiAwareScan();
  }

  Future<String?> _resolveWithTimeout(String hostname, int ms) async {
    try {
      final result = await Future.any([
        InternetAddress.lookup(hostname).then((r) => r.isNotEmpty ? r.first.address : null),
        Future.delayed(Duration(milliseconds: ms), () => null),
      ]);
      if (result != null && mounted) {
        setState(() {
          _status = '✅ Found ESP at $result via $hostname';
          _discoveredDevices.add(DiscoveredDevice(
            ip: result,
            status: 'mDNS: $hostname',
            timestamp: DateTime.now(),
          ));
        });
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> _wifiAwareScan() async {
    setState(() {
      _status = '📡 WiFi-aware scanning...';
      _isWifiScanning = true;
    });
    // Get current network info
    final info = NetworkInfo();
    String? wifiIP = await info.getWifiIP();
    List<String> scanList;
    if (wifiIP != null && wifiIP.isNotEmpty) {
      final parts = wifiIP.split('.');
      if (parts.length == 4) {
        final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
        setState(() => _status = '📡 Scanning subnet $subnet.x...');
        // Smart scan: Current subnet
        scanList = List.generate(50, (i) => '$subnet.${5 + i}');
      } else {
        scanList = _getDefaultScanList();
      }
    } else {
      scanList = _getDefaultScanList();
    }
    // Parallel scan with batching
    const batchSize = 10;
    for (int i = 0; i < scanList.length; i += batchSize) {
      if (!_isScanning) return;
      final batch = scanList.skip(i).take(batchSize).toList();
      final futures = batch.map((ip) => _testConnectionWithTimeout(ip, 600)).toList();
      if (mounted) {
        setState(() {
          _status = '📡 Scanned ${i}/${scanList.length} addresses...';
        });
      }
      final results = await Future.wait(futures);
      for (var result in results) {
        if (result != null && result != 'AP_MODE') {
          final device = DiscoveredDevice(
            ip: result,
            status: 'Active',
            timestamp: DateTime.now(),
          );
          if (!_discoveredDevices.any((d) => d.ip == result)) {
            setState(() => _discoveredDevices.add(device));
          }
          // Auto-connect to first found
          if (_discoveredDevices.length == 1) {
            _connectToEsp(result);
            return;
          }
        }
      }
    }
    // Scan complete
    if (mounted && _isScanning) {
      setState(() {
        _isScanning = false;
        _isWifiScanning = false;
        if (_discoveredDevices.isEmpty) {
          _status = '❌ No ESP devices found';
        } else {
          _status = '✅ Found ${_discoveredDevices.length} ESP device(s)';
        }
      });
    }
  }

  List<String> _getDefaultScanList() {
    return [
      ...List.generate(30, (i) => '192.168.1.${10 + i}'),
      ...List.generate(15, (i) => '192.168.0.${10 + i}'),
      '10.0.0.10', '10.0.0.20', '10.0.0.30',
      '172.16.0.10', '172.16.0.20',
      '192.168.4.1', // ESP AP
    ];
  }

  Future<String?> _testConnectionWithTimeout(String ip, int ms) async {
    try {
      return await Future.any([
        _testConnection(ip),
        Future.delayed(Duration(milliseconds: ms), () => null),
      ]);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _testConnection(String ip) async {
    try {
      final uri = Uri.parse('ws://$ip:80/');
      final channel = WebSocketChannel.connect(uri);
      final completer = Completer<String?>();
      late StreamSubscription sub;
      sub = channel.stream.listen((event) {
        if (event is String) {
          if (event.startsWith('IP:') || event.startsWith('AUTO_CONNECTED:')) {
            completer.complete(event.split(':').last.trim());
          } else if (event == 'AP_MODE') {
            completer.complete('AP_MODE');
          }
        }
      }, onError: (e, s) => completer.complete(null));
      final result = await Future.any([
        completer.future,
        Future.delayed(const Duration(seconds: 2), () => null),
      ]);
      await channel.sink.close();
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    }
  }

  void _connectToEsp(String ip) {
    if (ip == 'AP_MODE') {
      if (mounted) {
        setState(() {
          _status = '⚠️ ESP is in hotspot mode. Configure Wi‑Fi below.';
          _showManualSetup = true;
        });
      }
      return;
    }
    _saveLastKnownIP(ip);
    _reconnectAttempts = 0;
    if (mounted) {
      setState(() => _status = '✅ Found ESP at $ip! Connecting...');
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ColorControlScreen(initialIp: ip)),
      );
    }
  }

  void _retryDiscovery() {
    _visibilityTimer?.cancel();
    _reconnectAttempts = 0;
    setState(() {
      _isScanning = true;
      _showManualSetup = false;
      _status = '🔄 Retrying discovery...';
      _discoveredDevices.clear();
    });
    _startDiscovery();
    _visibilityTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isScanning) {
        setState(() => _showManualSetup = true);
      }
    });
  }

  Future<void> _showManualIpDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter ESP IP Address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the IP address of your ESP:'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'e.g., 192.168.1.23',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.of(context).pop();
                  _connectToEsp(value.trim());
                }
              },
            ),
            if (_currentWifiSSID != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.wifi, size: 16, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Connected to: $_currentWifiSSID',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.blue.withOpacity(0.1),
              child: const Text(
                '💡 Check ESP serial monitor for IP address',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () {
              final ip = controller.text.trim();
              if (ip.isNotEmpty) {
                Navigator.of(context).pop();
                _connectToEsp(ip);
              }
            },
            child: const Text('CONNECT'),
          ),
        ],
      ),
    );
  }

  void _showWifiScanDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        expand: false,
        builder: (context, scrollController) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                'Discovered ESP Devices',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _discoveredDevices.isEmpty
                    ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off, size: 64, color: Colors.grey[600]),
                      const SizedBox(height: 16),
                      Text(
                        'No devices found yet',
                        style: TextStyle(color: Colors.grey[400]),
                      ),
                    ],
                  ),
                )
                    : ListView.builder(
                  controller: scrollController,
                  itemCount: _discoveredDevices.length,
                  itemBuilder: (context, index) {
                    final device = _discoveredDevices[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.router, color: Colors.teal),
                        title: Text(
                          device.ip,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(device.status),
                        trailing: FilledButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _connectToEsp(device.ip);
                          },
                          child: const Text('CONNECT'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated status indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _isScanning ? _pulseAnimation.value : 1.0,
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            color: _isScanning
                                ? cs.primary.withOpacity(0.2)
                                : _status.contains('✅')
                                ? Colors.green.withOpacity(0.2)
                                : Colors.red.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: _isScanning
                                ? RotationTransition(
                              turns: _rotateController,
                              child: Icon(Icons.wifi_find, size: 40, color: cs.primary),
                            )
                                : _status.contains('✅')
                                ? const Icon(Icons.check_circle, size: 45, color: Colors.green)
                                : const Icon(Icons.error, size: 45, color: Colors.red),
                          ),
                        ),
                      );
                    },
                  ),
                  if (!_isScanning && !_status.contains('✅'))
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 36, color: Colors.blue),
                      onPressed: _retryDiscovery,
                      tooltip: 'Retry discovery',
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'ESP LED Controller',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Status card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _status.contains('✅')
                      ? Colors.green.withOpacity(0.15)
                      : _status.contains('⚠️') || _status.contains('❌')
                      ? Colors.red.withOpacity(0.15)
                      : cs.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: _status.contains('✅')
                            ? Colors.green
                            : _status.contains('❌') || _status.contains('⚠️')
                            ? Colors.red
                            : cs.primary,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (_currentWifiSSID != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.wifi, size: 16, color: cs.primary),
                          const SizedBox(width: 8),
                          Text(
                            _currentWifiSSID!,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.primary.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Action buttons
              if (!_isScanning || _showManualSetup)
                Column(
                  children: [
                    // Retry button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry Discovery', style: TextStyle(fontSize: 16)),
                        onPressed: _retryDiscovery,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          foregroundColor: Colors.blue,
                          side: const BorderSide(color: Colors.blue, width: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Show discovered devices
                    if (_discoveredDevices.isNotEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: Badge(
                            label: Text('${_discoveredDevices.length}'),
                            child: const Icon(Icons.devices),
                          ),
                          label: const Text('Show Discovered Devices', style: TextStyle(fontSize: 16)),
                          onPressed: _showWifiScanDialog,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            foregroundColor: Colors.green,
                            side: const BorderSide(color: Colors.green, width: 1.5),
                          ),
                        ),
                      ),
                    if (_discoveredDevices.isNotEmpty) const SizedBox(height: 12),
                    // Manual IP entry
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.edit_note, size: 20),
                        label: const Text('Enter IP Manually', style: TextStyle(fontSize: 16)),
                        onPressed: _showManualIpDialog,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          foregroundColor: Colors.orange,
                          side: const BorderSide(color: Colors.orange, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 16),
              // Setup via hotspot
              if (_showManualSetup)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.wifi, size: 20),
                    label: const Text('🔌 Set Up via ESP Hotspot', style: TextStyle(fontSize: 16)),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SetupInstructionsScreen()),
                      );
                    },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blue,
                    ),
                  ),
                ),
              const Spacer(),
              // Info card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(
                            text: '💡 Discovery Methods:\n',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const TextSpan(
                            text: '• Auto-reconnect to last IP\n'
                                '• mDNS (.local) resolution\n'
                                '• Smart subnet scanning\n',
                          ),
                          const TextSpan(
                            text: '✅ Quick Actions:\n',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const TextSpan(
                            text: '1. Wait for automatic discovery\n'
                                '2. View discovered devices\n'
                                '3. Enter IP manually if needed',
                          ),
                        ],
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.blue[200],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== SETUP INSTRUCTIONS =====
class SetupInstructionsScreen extends StatelessWidget {
  const SetupInstructionsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.background,
      appBar: AppBar(
        title: const Text('ESP Hotspot Setup'),
        backgroundColor: cs.surface,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connect to ESP Hotspot',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.primary, width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📱 Setup Steps',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildStep(context, 1, 'Open Wi‑Fi settings'),
                    const SizedBox(height: 12),
                    _buildStep(context, 2, 'Connect to:'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'SSID: ESP_LED',
                            style: TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Password: 12345678',
                            style: TextStyle(
                              color: Colors.yellowAccent,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontSize: 17,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _buildStep(context, 3, 'Wait for connection'),
                    const SizedBox(height: 12),
                    _buildStep(context, 4, 'Return to configure Wi‑Fi'),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const WifiConfigScreen()),
                    );
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('✅ Connected to ESP_LED → Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context, int number, String text) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: cs.primary,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

// ===== WIFI CONFIG SCREEN =====
class WifiConfigScreen extends StatefulWidget {
  const WifiConfigScreen({super.key});
  @override
  State<WifiConfigScreen> createState() => _WifiConfigScreenState();
}

class _WifiConfigScreenState extends State<WifiConfigScreen> {
  final _ssidController = TextEditingController();
  final _passController = TextEditingController();
  bool _isSending = false;
  String _status = 'Enter your home Wi‑Fi credentials';
  String? _discoveredIp;

  @override
  void dispose() {
    _ssidController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _sendCredentials() async {
    final ssid = _ssidController.text.trim();
    final pass = _passController.text.trim();
    if (ssid.isEmpty || pass.isEmpty) {
      setState(() => _status = '⚠️ Both fields required');
      return;
    }
    setState(() {
      _isSending = true;
      _status = '📡 Sending credentials...';
    });
    try {
      final uri = Uri.parse('ws://192.168.4.1:80/');
      final channel = WebSocketChannel.connect(uri);
      final ssidBytes = Uint8List.fromList(ssid.codeUnits);
      final passBytes = Uint8List.fromList(pass.codeUnits);
      final payload = Uint8List(2 + ssidBytes.length + passBytes.length)
        ..[0] = ssidBytes.length
        ..[1] = passBytes.length
        ..setAll(2, ssidBytes)
        ..setAll(2 + ssidBytes.length, passBytes);
      channel.sink.add(payload);
      final completer = Completer<String>();
      late StreamSubscription sub;
      sub = channel.stream.listen((event) {
        if (event is String) {
          if (event.startsWith('IP:') || event.startsWith('AUTO_CONNECTED:')) {
            completer.complete(event.split(':').last.trim());
          } else if (event.startsWith('FAIL:')) {
            completer.completeError(event.substring(5));
          }
        }
      }, onError: (e, s) => completer.completeError(e));
      final ip = await Future.any([
        completer.future,
        Future.delayed(const Duration(seconds: 25), () => throw TimeoutException('No response')),
      ]);
      await channel.sink.close();
      await sub.cancel();
      if (mounted) {
        setState(() {
          _status = '✅ ESP connected to Wi‑Fi!';
          _discoveredIp = ip;
        });
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => ReconnectInstructionsScreen(espIp: ip)),
            );
          }
        });
      }
    } on TimeoutException catch (e) {
      if (mounted) setState(() => _status = '⏱️ ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status = '❌ ${e.toString().split(":").first}');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.background,
      appBar: AppBar(
        title: const Text('Configure Wi‑Fi'),
        backgroundColor: cs.surface,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Stay connected to "ESP_LED" hotspot',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.primary),
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _ssidController,
                decoration: const InputDecoration(
                  labelText: 'Home Wi‑Fi SSID',
                  border: OutlineInputBorder(),
                  filled: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  filled: true,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isSending ? null : _sendCredentials,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isSending
                      ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                      : const Text('Connect ESP to Wi‑Fi'),
                ),
              ),
              const SizedBox(height: 16),
              Text(_status, style: TextStyle(
                color: _status.contains('✅') ? Colors.green : Colors.orange,
              )),
              if (_discoveredIp != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ESP IP Address:',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _discoveredIp!,
                        style: const TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ===== RECONNECT INSTRUCTIONS =====
class ReconnectInstructionsScreen extends StatelessWidget {
  final String espIp;
  const ReconnectInstructionsScreen({super.key, required this.espIp});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('📱 Switch to Home Wi‑Fi', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.green, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '✅ ESP Connected!',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'ESP IP: '),
                          TextSpan(
                            text: espIp,
                            style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontSize: 19,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Next Steps:',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                    ),
                    SizedBox(height: 14),
                    Text(
                      '1. Open Wi‑Fi settings\n'
                          '2. Disconnect from "ESP_LED"\n'
                          '3. Connect to your home Wi‑Fi\n'
                          '4. Return and tap Continue',
                      style: TextStyle(height: 1.6),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => ColorControlScreen(initialIp: espIp)),
                    );
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Continue to Controller'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== COLOR CONTROL SCREEN WITH EFFECTS PAGE =====
class ColorControlScreen extends StatefulWidget {
  final String initialIp;
  const ColorControlScreen({super.key, required this.initialIp});
  @override
  State<ColorControlScreen> createState() => _ColorControlScreenState();
}

class _ColorControlScreenState extends State<ColorControlScreen> with TickerProviderStateMixin {
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  String _status = 'Connecting...';
  late final TextEditingController _ipController;
  int _currentMode = MODE_STATIC;
  Color _currentColor = Colors.cyan;
  double _brightness = 1.0;
  // Animation for connection status
  late AnimationController _statusAnimController;
  late Animation<double> _statusPulse;
  // Animation for mode changes
  late AnimationController _modeChangeController;
  bool _isChangingMode = false;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(text: widget.initialIp);
    // Status pulse animation
    _statusAnimController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);
    _statusPulse = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _statusAnimController, curve: Curves.easeInOut),
    );
    // Mode change animation
    _modeChangeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    Future.delayed(const Duration(milliseconds: 300), _connectWs);
  }

  @override
  void dispose() {
    _ipController.dispose();
    _wsSub?.cancel();
    _channel?.sink.close();
    _statusAnimController.dispose();
    _modeChangeController.dispose();
    super.dispose();
  }

  void _connectWs() {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) {
      setState(() => _status = '⚠️ Enter ESP IP');
      return;
    }
    _wsSub?.cancel();
    _channel?.sink.close();
    _channel = null;
    setState(() => _status = '🔌 Connecting to $ip...');
    try {
      final uri = Uri.parse('ws://$ip:80/');
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _wsSub = channel.stream.listen(
            (event) {
          if (event is String && mounted) {
            setState(() {
              if (event.startsWith('IP:') || event.startsWith('AUTO_CONNECTED:')) {
                _status = '✅ Connected to ${event.split(':').last.trim()}';
              } else if (event == 'AP_MODE') {
                _status = '⚠️ ESP in hotspot mode';
              } else {
                _status = event;
              }
            });
          }
        },
        onError: (e, s) {
          if (mounted) {
            setState(() => _status = '❌ ${e.toString().split("\n").first}');
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _status = 'Disconnected';
              _channel = null;
            });
          }
        },
      );
    } catch (e) {
      setState(() => _status = '❌ Connection failed');
    }
  }

  void _sendColor(Color c) {
    if (_channel == null) return;
    final bytes = Uint8List.fromList([0x01, c.red, c.green, c.blue]);
    _channel!.sink.add(bytes);
  }

  void _sendBrightness(double v) {
    if (_channel == null) return;
    final b = (v * 255).clamp(0, 255).toInt();
    final bytes = Uint8List.fromList([0x03, b]);
    _channel!.sink.add(bytes);
  }

  void _sendMode(int mode) async {
    if (_channel == null) return;
    setState(() {
      _isChangingMode = true;
      _currentMode = mode;
    });
    // Trigger animation
    _modeChangeController.forward(from: 0);
    final bytes = Uint8List.fromList([0x02, mode]);
    _channel!.sink.add(bytes);
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) {
      setState(() => _isChangingMode = false);
    }
  }

  void _navigateToEffectsPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EffectsGalleryScreen(
          currentMode: _currentMode,
          onModeSelected: _sendMode,
          isConnected: _channel != null,
        ),
      ),
    );
  }

  void _navigateToAudioVisualizer() {
    if (_channel != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AudioVisualizerScreen(
            espIp: _ipController.text.trim(),
            channel: _channel,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to ESP first')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = _currentMode == MODE_STATIC ? _currentColor.withOpacity(1.0) : Theme.of(context).colorScheme.background;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              color: cs.surface.withOpacity(0.92),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Disconnect?'),
                          content: const Text('Return to connection screen?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('CANCEL'),
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                                Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(builder: (_) => const SmartConnectionScreen()),
                                );
                              },
                              child: const Text('DISCONNECT', style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('LED Controller', style: Theme.of(context).textTheme.titleLarge),
                        TextField(
                          controller: _ipController,
                          decoration: InputDecoration(
                            hintText: 'ESP IP',
                            contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                            isDense: true,
                            filled: true,
                            fillColor: cs.surface,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.refresh_rounded, size: 20),
                              onPressed: _connectWs,
                              splashRadius: 20,
                            ),
                          ),
                          onSubmitted: (_) => _connectWs(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Status bar with animation
            AnimatedBuilder(
              animation: _statusPulse,
              builder: (context, child) {
                return Container(
                  color: cs.surface.withOpacity(0.85),
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_status.contains('🔌'))
                        Transform.scale(
                          scale: _statusPulse.value,
                          child: const Icon(Icons.sync, size: 16, color: Colors.orange),
                        ),
                      if (_status.contains('✅'))
                        const Icon(Icons.check_circle, size: 16, color: Colors.green),
                      if (_status.contains('❌'))
                        const Icon(Icons.error, size: 16, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: _status.contains('✅')
                                ? Colors.green
                                : _status.contains('❌')
                                ? Colors.red
                                : cs.primary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            // Main content
            if (_currentMode == MODE_STATIC)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white.withOpacity(0.2)),
                  ),
                  child: Column(
                    children: [
                      ColorPicker(
                        color: _currentColor,
                        onColorChanged: (c) {
                          setState(() => _currentColor = c);
                          _sendColor(c);
                        },
                        width: 44,
                        height: 44,
                        borderRadius: 22,
                        heading: Text(
                          'Pick Color',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        pickersEnabled: const <ColorPickerType, bool>{
                          ColorPickerType.primary: true,
                          ColorPickerType.wheel: true,
                        },
                      ),
                      const SizedBox(height: 24),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Brightness',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                '${(_brightness * 100).toInt()}%',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Slider(
                            value: _brightness,
                            onChanged: (v) {
                              setState(() => _brightness = v);
                              _sendBrightness(v);
                              _sendColor(_currentColor);
                            },
                            min: 0.0,
                            max: 1.0,
                            activeColor: _currentColor,
                            inactiveColor: Colors.white24,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: FadeTransition(
                  opacity: _modeChangeController,
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white.withOpacity(0.2)),
                    ),
                    child: _buildModePreview(_currentMode),
                  ),
                ),
              ),
            // Quick mode selector with AUDIO BUTTON
            Container(
              color: cs.surface.withOpacity(0.9),
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  Row(
                    children: [
                      _buildQuickModeButton('Static', MODE_STATIC, Icons.color_lens),
                      const SizedBox(width: 8),
                      _buildQuickModeButton('Rainbow', MODE_RAINBOW, Icons.gradient),
                      const SizedBox(width: 8),
                      _buildQuickModeButton('Fire', MODE_FIRE, Icons.whatshot),
                      const SizedBox(width: 8),
                      // NEW AUDIO BUTTON
                      Expanded(
                        child: FilledButton.tonal(
                          style: ButtonStyle(
                            backgroundColor: MaterialStateProperty.resolveWith(
                                  (s) => _currentMode >= MODE_AUDIO_SPECTRUM && _currentMode <= MODE_AUDIO_RAINBOW_BARS
                                  ? cs.primary
                                  : null,
                            ),
                            foregroundColor: MaterialStateProperty.resolveWith(
                                  (s) => _currentMode >= MODE_AUDIO_SPECTRUM && _currentMode <= MODE_AUDIO_RAINBOW_BARS
                                  ? Colors.white
                                  : null,
                            ),
                          ),
                          onPressed: _navigateToAudioVisualizer,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.music_note, size: 24),
                              const SizedBox(height: 4),
                              const Text('Audio', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('View All Effects'),
                      onPressed: _navigateToEffectsPage,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Info bar for static mode
            if (_currentMode == MODE_STATIC)
              Container(
                color: cs.surface.withOpacity(0.85),
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _currentColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white30, width: 1.5),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'RGB(${_currentColor.red}, ${_currentColor.green}, ${_currentColor.blue}) • '
                            '${(_brightness * 100).toInt()}%',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickModeButton(String label, int modeValue, IconData icon) {
    final isActive = _currentMode == modeValue;
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: FilledButton.tonal(
        style: ButtonStyle(
          backgroundColor: MaterialStateProperty.resolveWith(
                (s) => isActive ? cs.primary : null,
          ),
          foregroundColor: MaterialStateProperty.resolveWith(
                (s) => isActive ? Colors.white : null,
          ),
        ),
        onPressed: () => _sendMode(modeValue),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModePreview(int mode) {
    IconData icon;
    Color color;
    String title;
    String description;
    switch (mode) {
      case MODE_RAINBOW:
        icon = Icons.gradient;
        color = Colors.cyan;
        title = '🌈 Rainbow Flow';
        description = 'Smooth color transitions across all LEDs';
        break;
      case MODE_FIRE:
        icon = Icons.whatshot;
        color = Colors.orange;
        title = '🔥 Fire Effect';
        description = 'Realistic flickering flames with heat physics';
        break;
      case MODE_PALETTE:
        icon = Icons.palette;
        color = Colors.purple;
        title = '🎨 Color Palettes';
        description = 'Cycles through 8 professional palettes';
        break;
      case MODE_CYLON:
        icon = Icons.chevron_right;
        color = Colors.red;
        title = '🔴 Cylon Scanner';
        description = 'Classic red scanner with fading trail';
        break;
      case MODE_PACIFICA:
        icon = Icons.waves;
        color = Colors.blue;
        title = '🌊 Pacifica';
        description = 'Peaceful ocean waves effect';
        break;
      case MODE_PRIDE:
        icon = Icons.favorite;
        color = Colors.pink;
        title = '🏳️‍🌈 Pride';
        description = 'Ever-changing rainbow effect';
        break;
      case MODE_PLASMA:
        icon = Icons.blur_on;
        color = Colors.deepPurple;
        title = '💫 Plasma';
        description = 'Colorful plasma waves';
        break;
      case MODE_AURORA:
        icon = Icons.auto_awesome;
        color = Colors.green;
        title = '🌌 Aurora';
        description = 'Northern lights simulation';
        break;
      case MODE_MATRIX:
        icon = Icons.code;
        color = Colors.greenAccent;
        title = '💚 Matrix';
        description = 'Matrix-style digital rain';
        break;
      case MODE_AUDIO_SPECTRUM:
        icon = Icons.equalizer;
        color = Colors.deepPurple;
        title = '🎵 Audio Spectrum';
        description = 'Reactive EQ bars synced to music';
        break;
      case MODE_AUDIO_WAVE:
        icon = Icons.waves;
        color = Colors.cyan;
        title = '🌊 Audio Wave';
        description = 'Pulsing waves that flow with music energy';
        break;
      case MODE_AUDIO_ENERGY:
        icon = Icons.bolt;
        color = Colors.red;
        title = '⚡ Audio Energy';
        description = 'Full-strip glow that pulses with beats';
        break;
      case MODE_AUDIO_PARTICLES:
        icon = Icons.scatter_plot;
        color = Colors.pink;
        title = '✨ Beat Particles';
        description = 'Particles explode on detected beats';
        break;
      case MODE_AUDIO_RAINBOW_BARS:
        icon = Icons.colorize;
        color = Colors.amber;
        title = '🌈 Rainbow Bars';
        description = 'Vibrant spectrum with peak hold indicators';
        break;
      default:
        icon = Icons.color_lens;
        color = Colors.grey;
        title = 'Static';
        description = 'Solid color';
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          description,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.white70,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

// ===== EFFECTS GALLERY SCREEN =====
class EffectsGalleryScreen extends StatelessWidget {
  final int currentMode;
  final Function(int) onModeSelected;
  final bool isConnected;
  const EffectsGalleryScreen({
    super.key,
    required this.currentMode,
    required this.onModeSelected,
    required this.isConnected,
  });
  @override
  Widget build(BuildContext context) {
    final effects = [
      EffectInfo(
        mode: MODE_STATIC,
        name: 'Static Color',
        icon: Icons.color_lens,
        color: Colors.cyan,
        description: 'Solid color with brightness control. Perfect for ambient lighting.',
        category: 'Basic',
      ),
      EffectInfo(
        mode: MODE_RAINBOW,
        name: 'Rainbow Flow',
        icon: Icons.gradient,
        color: Colors.amber,
        description: 'Smooth flowing rainbow across all LEDs with seamless color transitions.',
        category: 'Dynamic',
      ),
      EffectInfo(
        mode: MODE_FIRE,
        name: 'Fire Effect',
        icon: Icons.whatshot,
        color: Colors.deepOrange,
        description: 'Realistic flickering flames using heat physics simulation.',
        category: 'Animated',
      ),
      EffectInfo(
        mode: MODE_PALETTE,
        name: 'Color Palettes',
        icon: Icons.palette,
        color: Colors.purple,
        description: 'Auto-cycling through 8 professional color palettes every 10 seconds.',
        category: 'Dynamic',
      ),
      EffectInfo(
        mode: MODE_CYLON,
        name: 'Cylon Scanner',
        icon: Icons.chevron_right,
        color: Colors.red,
        description: 'Classic bouncing red scanner with smooth fading trail.',
        category: 'Retro',
      ),
      EffectInfo(
        mode: MODE_PACIFICA,
        name: 'Pacifica',
        icon: Icons.waves,
        color: Colors.blue,
        description: 'Peaceful ocean waves with layered animations. Calming and meditative.',
        category: 'Nature',
      ),
      EffectInfo(
        mode: MODE_PRIDE,
        name: 'Pride Rainbow',
        icon: Icons.favorite,
        color: Colors.pink,
        description: 'Ever-changing rainbow with brightness waves. Celebrating diversity.',
        category: 'Special',
      ),
      EffectInfo(
        mode: MODE_PLASMA,
        name: 'Plasma Waves',
        icon: Icons.blur_on,
        color: Colors.deepPurple,
        description: 'Colorful plasma effect with interference patterns.',
        category: 'Advanced',
      ),
      EffectInfo(
        mode: MODE_AURORA,
        name: 'Aurora Borealis',
        icon: Icons.auto_awesome,
        color: Colors.green,
        description: 'Northern lights simulation with flowing green, cyan, and purple bands.',
        category: 'Nature',
      ),
      EffectInfo(
        mode: MODE_MATRIX,
        name: 'Matrix Rain',
        icon: Icons.code,
        color: Colors.greenAccent,
        description: 'Matrix-style digital rain with cascading green characters.',
        category: 'Retro',
      ),
      // ===== AUDIO VISUALIZATION EFFECTS =====
      EffectInfo(
        mode: MODE_AUDIO_SPECTRUM,
        name: 'Audio Spectrum',
        icon: Icons.equalizer,
        color: Colors.deepPurple,
        description: 'Classic EQ bars reacting to 16 frequency bands. Bass=red, treble=blue.',
        category: 'Audio',
      ),
      EffectInfo(
        mode: MODE_AUDIO_WAVE,
        name: 'Audio Wave',
        icon: Icons.waves,
        color: Colors.cyan,
        description: 'Smooth pulsing waves that flow with music energy and beat detection.',
        category: 'Audio',
      ),
      EffectInfo(
        mode: MODE_AUDIO_ENERGY,
        name: 'Audio Energy',
        icon: Icons.bolt,
        color: Colors.red,
        description: 'Full-strip glow that pulses with overall volume and flashes on beats.',
        category: 'Audio',
      ),
      EffectInfo(
        mode: MODE_AUDIO_PARTICLES,
        name: 'Beat Particles',
        icon: Icons.scatter_plot,
        color: Colors.pink,
        description: 'Particles explode from center on detected beats with colorful trails.',
        category: 'Audio',
      ),
      EffectInfo(
        mode: MODE_AUDIO_RAINBOW_BARS,
        name: 'Rainbow Bars',
        icon: Icons.colorize,
        color: Colors.amber,
        description: 'Vibrant rainbow spectrum bars with peak hold indicators and shimmer effects.',
        category: 'Audio',
      ),
    ];
    final categories = effects.map((e) => e.category).toSet().toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('LED Effects Gallery'),
        actions: [
          if (!isConnected)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 16, color: Colors.red),
                      const SizedBox(width: 6),
                      Text(
                        'Disconnected',
                        style: TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: categories.length,
        itemBuilder: (context, catIndex) {
          final category = categories[catIndex];
          final categoryEffects = effects.where((e) => e.category == category).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  category,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ...categoryEffects.map((effect) => _buildEffectCard(context, effect)),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEffectCard(BuildContext context, EffectInfo effect) {
    final isActive = currentMode == effect.mode;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isActive ? cs.primary.withOpacity(0.2) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isActive
            ? BorderSide(color: cs.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: isConnected
            ? () {
          onModeSelected(effect.mode);
          Navigator.of(context).pop();
        }
            : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: effect.color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(effect.icon, size: 32, color: effect.color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            effect.name,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: isActive ? cs.primary : null,
                            ),
                          ),
                        ),
                        if (isActive)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'ACTIVE',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      effect.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[400],
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isActive)
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey[600],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class EffectInfo {
  final int mode;
  final String name;
  final IconData icon;
  final Color color;
  final String description;
  final String category;
  EffectInfo({
    required this.mode,
    required this.name,
    required this.icon,
    required this.color,
    required this.description,
    required this.category,
  });
}

// Extension for rainbow color
extension on Colors {
  static const Color rainbow = Color(0xFF00D9FF);
}

// ===== AUDIO VISUALIZER SCREEN (FULLY FIXED - SINGLE IMPLEMENTATION) =====
class AudioVisualizerScreen extends StatefulWidget {
  final String espIp;
  final WebSocketChannel? channel;
  final VoidCallback? onConnectionLost;

  const AudioVisualizerScreen({
    super.key,
    required this.espIp,
    this.channel,
    this.onConnectionLost,
  });

  @override
  State<AudioVisualizerScreen> createState() => _AudioVisualizerScreenState();
}

class _AudioVisualizerScreenState extends State<AudioVisualizerScreen> with WidgetsBindingObserver {
  // ===== AUDIO MODES CONFIGURATION =====
  static const List<AudioModeConfig> _audioModes = [
    AudioModeConfig(
      mode: MODE_AUDIO_SPECTRUM,
      name: 'Spectrum',
      icon: Icons.equalizer,
      color: Colors.deepPurple,
      description: 'Classic EQ bars: Bass=red → Treble=blue',
    ),
    AudioModeConfig(
      mode: MODE_AUDIO_WAVE,
      name: 'Wave',
      icon: Icons.waves,
      color: Colors.cyan,
      description: 'Pulsing waves flowing with music energy',
    ),
    AudioModeConfig(
      mode: MODE_AUDIO_ENERGY,
      name: 'Energy',
      icon: Icons.bolt,
      color: Colors.red,
      description: 'Full-strip glow with beat flashes',
    ),
    AudioModeConfig(
      mode: MODE_AUDIO_PARTICLES,
      name: 'Particles',
      icon: Icons.scatter_plot,
      color: Colors.pink,
      description: 'Particles explode on detected beats',
    ),
    AudioModeConfig(
      mode: MODE_AUDIO_RAINBOW_BARS,
      name: 'Rainbow',
      icon: Icons.colorize,
      color: Colors.amber,
      description: 'Vibrant spectrum with peak indicators',
    ),
  ];

  // ===== STATE VARIABLES =====
  String _status = 'Tap START to begin audio capture';
  bool _isCapturing = false;
  bool _isPaused = false;
  bool _isConnected = true;
  bool _hasPermission = false;
  bool _isStopping = false;
  int _currentAudioModeIndex = 0; // Default to Spectrum

  // CRITICAL: Throttle to exactly 15fps (66ms) for ESP8266 stability
  static const int AUDIO_SEND_INTERVAL_MS = 25;
  DateTime _lastAudioSend = DateTime.now();

  // Audio processing state
  bool _isActuallyRecording = false;
  StreamSubscription? _audioSubscription;
  Timer? _heartbeatTimer;
  Timer? _audioSendTimer;
  Timer? _backgroundGraceTimer;

  // Visualizer state (16 bins with dual smoothing)
  final List<double> _currentBins = List.filled(16, 0.0);
  final List<double> _smoothedBins = List.filled(16, 0.0);
  final List<double> _peakHold = List.filled(16, 0.0);
  final List<int> _peakDecayTimer = List.filled(16, 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _initForegroundTask();  // ← ADD THIS LINE

    _startHeartbeat();
    _setupAudioSession();

    if (widget.channel != null) {
      _setEspMode(_audioModes[_currentAudioModeIndex].mode);
    } else {
      setState(() {
        _isConnected = false;
        _status = '⚠️ Not connected to ESP - audio capture disabled';
      });
    }
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'audio_visualizer',
        channelName: 'Audio Visualizer',
        channelDescription: 'Keeps audio capture alive in background',
        channelImportance: NotificationChannelImportance.LOW,  // No sound
        priority: NotificationPriority.LOW,
        // Small icon — must exist in android/app/src/main/res/drawable/
        // If you don't have one, use the default Flutter icon
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(),  // Not used
      foregroundTaskOptions: ForegroundTaskOptions(
        // eventAction: ForegroundTaskEventAction.repeat(1000),  // heartbeat every 1s
        interval: 1000,
        isOnceEvent: false,
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,  // Keep WiFi alive for WebSocket
      ),
    );
  }

  Future<void> _setupAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
        AVAudioSessionCategoryOptions.defaultToSpeaker |
        AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.measurement,
        avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
        // FIXED: Use plural form AudioSessionSetActiveOptions (not singular)
        // avAudioSessionSetActiveOptions: AudioSessionSetActiveOptions.none,
      ));
      await session.setActive(true);
    } catch (e) {
      debugPrint('Audio session setup failed: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 3),
          (timer) {
        if (!_isConnected || widget.channel == null) return;
        try {
          _setEspMode(_audioModes[_currentAudioModeIndex].mode);
        } catch (e) {
          debugPrint('Heartbeat failed: $e');
          _handleConnectionLost();
          timer.cancel();
        }
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Foreground service keeps us alive — just update status
      if (_isCapturing && !_isPaused && mounted) {
        setState(() => _status = '📱 Running in background (foreground service active)');
      }
    } else if (state == AppLifecycleState.resumed) {
      _backgroundGraceTimer?.cancel();
      if (_isCapturing && mounted) {
        setState(() => _status = _isPaused
            ? '⏸️ Audio paused (tap RESUME to continue)'
            : '🎤 Capturing audio (${_audioModes[_currentAudioModeIndex].name})');
      }
    }
  }

  Future<bool> _requestPermission() async {
    if (_hasPermission) return true;

    setState(() => _status = 'Requesting audio permission...');
    try {
      final hasPermission = await SystemAudioRecorder.requestRecord();
      if (hasPermission == true) {
        setState(() => _hasPermission = true);
        return true;
      } else {
        setState(() => _status = '❌ Permission denied. Enable "Microphone" permission in Settings');
        return false;
      }
    } catch (e) {
      setState(() => _status = '❌ Permission error: ${e.toString().split("\n").first}');
      return false;
    }
  }

  Future<void> _startCapture() async {
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to ESP first')),
      );
      return;
    }

    if (_isCapturing || _isStopping) return;
    if (!_hasPermission && !(await _requestPermission())) return;

    setState(() {
      _isCapturing = true;
      _isPaused = false;
      _status = '🎤 Capturing audio (${_audioModes[_currentAudioModeIndex].name})...';
    });

    try {
      // ===== START FOREGROUND SERVICE FIRST =====
      await _startForegroundService();

      // Clean stop before restart
      await _forceStopRecording();

      // Start recording
      await SystemAudioRecorder.startRecord(
        toStream: true,
        sampleRate: 22050,
      );
      _isActuallyRecording = true;

      // Setup stream listener
      _audioSubscription = SystemAudioRecorder.audioStream
          .receiveBroadcastStream(<String, dynamic>{
        'sampleRate': 22050,
        'encoding': 'pcm16bit',
      }).listen(
        _processAudioBuffer,
        onError: (error) {
          if (mounted) setState(() => _status = '⚠️ Audio error: ${error.toString().split("\n").first}');
          _stopCaptureGracefully();
        },
        onDone: _stopCaptureGracefully,
        cancelOnError: true,
      );

      // Start throttled sending
      _startAudioSendTimer();
      _setEspMode(_audioModes[_currentAudioModeIndex].mode);

    } catch (e) {
      final errorMsg = e.toString().split('\n').first;
      if (mounted) setState(() => _status = '❌ Capture failed: $errorMsg');
      await _forceStopRecording();
      await _stopForegroundService();
      if (mounted) setState(() => _isCapturing = false);
    }
  }

// ===== FOREGROUND SERVICE HELPERS =====
  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      notificationTitle: '🎵 Audio Visualizer Active',
      notificationText: 'Streaming audio to ESP LEDs',
      callback: startCallback,
    );
    debugPrint('[FG] Foreground service started');
  }

  Future<void> _stopForegroundService() async {
    if (!await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.stopService();
    debugPrint('[FG] Foreground service stopped');
  }

  void _startAudioSendTimer() {
    _audioSendTimer?.cancel();
    _audioSendTimer = Timer.periodic(
      Duration(milliseconds: AUDIO_SEND_INTERVAL_MS),
          (_) => _sendToEspIfReady(),
    );
  }

  // ===== IMPROVED AUDIO PROCESSING (Band-pass filtering) =====
  void _processAudioBuffer(dynamic rawData) {
    if (!_isCapturing || _isPaused || rawData == null) return;

    try {
      // Convert raw bytes to normalized samples (-1.0 to 1.0)
      final List<int> bytes = rawData is Uint8List
          ? rawData.toList()
          : (rawData is List ? List<int>.from(rawData) : []);

      if (bytes.isEmpty || bytes.length < 128) return;

      final int numSamples = (bytes.length / 2).floor();
      final samples = List<double>.generate(numSamples, (i) {
        int raw = (bytes[i * 2 + 1] << 8) | (bytes[i * 2] & 0xFF);
        if (raw > 32767) raw -= 65536;
        return raw / 32768.0;
      });

      // ===== FREQUENCY ANALYSIS (Band-pass approximation) =====
      _processWithBandPass(samples);

      // Update peak hold (visual feedback)
      for (int i = 0; i < 16; i++) {
        if (_smoothedBins[i] > _peakHold[i]) {
          _peakHold[i] = _smoothedBins[i];
          _peakDecayTimer[i] = 8; // Hold for ~0.5 seconds at 15fps
        } else if (_peakDecayTimer[i] > 0) {
          _peakDecayTimer[i]--;
          if (_peakDecayTimer[i] == 0 && _peakHold[i] > 0.1) {
            _peakHold[i] *= 0.85; // Smooth decay
          }
        }
      }

      if (mounted) setState(() {});

    } catch (e) {
      debugPrint('Audio processing error: $e');
    }
  }

  void _processWithBandPass(List<double> samples) {
    final int N = samples.length;
    if (N < 512) return;

    // Use a fixed window of 1024 samples (or less if not enough)
    final int windowSize = math.min(1024, N);
    final int offset = N - windowSize; // use latest samples
    final double sampleRate = 22050.0;

    // Pre-apply Hanning window to reduce spectral leakage
    final windowed = List<double>.generate(windowSize, (i) {
      final w = 0.5 * (1 - math.cos(2 * math.pi * i / (windowSize - 1)));
      return samples[offset + i] * w;
    });

    for (int band = 0; band < 16; band++) {
      // Logarithmic center frequencies: ~60Hz to ~8kHz
      final double freqLow = 60.0 * math.pow(2.0, band * 0.47);
      final double freqHigh = 60.0 * math.pow(2.0, (band + 1) * 0.47);
      final double freqCenter = (freqLow + freqHigh) / 2.0;

      // Goertzel algorithm for this frequency
      final int kLow = (freqLow * windowSize / sampleRate).round().clamp(1, windowSize ~/ 2);
      final int kHigh = (freqHigh * windowSize / sampleRate).round().clamp(kLow, windowSize ~/ 2);

      double bandEnergy = 0.0;
      int binCount = 0;

      for (int k = kLow; k <= kHigh; k++) {
        // Goertzel for bin k
        final double omega = 2.0 * math.pi * k / windowSize;
        final double coeff = 2.0 * math.cos(omega);
        double s0 = 0, s1 = 0, s2 = 0;

        for (int n = 0; n < windowSize; n++) {
          s0 = windowed[n] + coeff * s1 - s2;
          s2 = s1;
          s1 = s0;
        }

        final double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
        bandEnergy += power;
        binCount++;
      }

      if (binCount > 0) bandEnergy /= binCount;

      // Convert power to perceptual amplitude (sqrt for power→amplitude)
      double amplitude = math.sqrt(bandEnergy) / (windowSize * 0.5);

      // Gentle per-band normalization (compensate for pink noise spectrum)
      if (band < 2) amplitude *= 1.4;       // Sub-bass: slight boost
      else if (band < 5) amplitude *= 1.2;   // Bass/low-mid
      else if (band < 10) amplitude *= 1.0;  // Mids: neutral
      else amplitude *= 1.3;                  // Treble: compensate rolloff

      amplitude = amplitude.clamp(0.0, 1.0);
      _currentBins[band] = amplitude;

      // Responsive smoothing: fast attack, medium decay
      if (amplitude > _smoothedBins[band]) {
        _smoothedBins[band] = _smoothedBins[band] * 0.2 + amplitude * 0.8;  // Fast attack
      } else {
        _smoothedBins[band] = _smoothedBins[band] * 0.7 + amplitude * 0.3;  // Smooth decay
      }
    }
  }

  void _sendToEspIfReady() {
    // Strict throttling enforcement
    final now = DateTime.now();
    if (now.difference(_lastAudioSend).inMilliseconds < AUDIO_SEND_INTERVAL_MS - 2) return;
    _lastAudioSend = now;

    if (widget.channel == null || !_isConnected || _isStopping || _isPaused) return;

    try {
      final packet = Uint8List(17);
      packet[0] = 0x04; // Audio command

      for (int i = 0; i < 16; i++) {
        double raw = _smoothedBins[i];

        // Non-linear expansion for LED perceptual response (gamma ~1.6)
        double expanded = math.pow(raw.clamp(0.0, 1.0), 0.65) * 1.2;

        int val = (expanded * 255).toInt().clamp(0, 255);
        packet[i + 1] = val;
      }

      widget.channel!.sink.add(packet);
    } catch (e) {
      debugPrint('WebSocket send error: $e');
      _handleConnectionLost();
    }
  }

  void _setEspMode(int mode) {
    if (widget.channel == null || !_isConnected) return;
    try {
      widget.channel!.sink.add(Uint8List.fromList([0x02, mode]));
    } catch (e) {
      debugPrint('Mode command failed: $e');
      _handleConnectionLost();
    }
  }

  // CRITICAL: Safe stop sequence
  Future<void> _forceStopRecording() async {
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _audioSendTimer?.cancel();
    _audioSendTimer = null;

    if (_isActuallyRecording) {
      _isActuallyRecording = false;
      try {
        await SystemAudioRecorder.stopRecord();
      } catch (e) {
        debugPrint('Stop record error (safe to ignore): $e');
      }
      await Future.delayed(const Duration(milliseconds: 250)); // Native cleanup
    }
  }

  Future<void> _stopCaptureGracefully() async {
    if (_isStopping || !_isCapturing) return;
    _isStopping = true;
    _backgroundGraceTimer?.cancel();

    if (mounted) setState(() => _status = '⏹️ Stopping capture safely...');

    try {
      await _forceStopRecording();
      // ===== STOP FOREGROUND SERVICE =====
      await _stopForegroundService();
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
          _isStopping = false;
          _isPaused = false;
          _status = _isConnected
              ? '✅ Capture stopped - tap START to resume'
              : '⚠️ Disconnected - reconnect to use audio visualizer';
        });
      }
    }
  }

  void _pauseCapture() {
    if (!_isCapturing || _isPaused) return;
    setState(() {
      _isPaused = true;
      _status = '⏸️ Audio paused (tap RESUME to continue)';
    });
    // Update notification directly
    FlutterForegroundTask.updateService(
      notificationTitle: '⏸️ Audio Visualizer Paused',
      notificationText: 'Tap to resume',
    );
  }

  void _resumeCapture() {
    if (!_isCapturing || !_isPaused) return;
    setState(() {
      _isPaused = false;
      _status = '🎤 Capturing audio (${_audioModes[_currentAudioModeIndex].name})';
    });
    _lastAudioSend = DateTime.now();
    FlutterForegroundTask.updateService(
      notificationTitle: '🎵 Audio Visualizer Active',
      notificationText: 'Streaming audio to ESP LEDs',
    );
  }

  void _changeAudioMode(int newIndex) {
    if (newIndex < 0 || newIndex >= _audioModes.length || newIndex == _currentAudioModeIndex) return;

    setState(() {
      _currentAudioModeIndex = newIndex;
      _status = '🎛️ Mode: ${_audioModes[newIndex].name} - ${_audioModes[newIndex].description}';
    });

    // Immediately update ESP mode
    _setEspMode(_audioModes[newIndex].mode);

    // Reset visualizer state for clean transition
    _currentBins.fillRange(0, 16, 0.0);
    _smoothedBins.fillRange(0, 16, 0.0);
    _peakHold.fillRange(0, 16, 0.0);
  }

  void _handleConnectionLost() {
    if (!_isConnected) return;
    setState(() {
      _isConnected = false;
      _status = '⚠️ ESP disconnected - audio capture paused';
    });

    _heartbeatTimer?.cancel();
    _audioSendTimer?.cancel();
    _backgroundGraceTimer?.cancel();

    // Pause but don't fully stop (user can reconnect)
    if (_isCapturing && !_isPaused) {
      _pauseCapture();
    }

    widget.onConnectionLost?.call();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _audioSendTimer?.cancel();
    _backgroundGraceTimer?.cancel();

    if (_isActuallyRecording) {
      _isActuallyRecording = false;
      SystemAudioRecorder.stopRecord().catchError((_) {});
    }
    _audioSubscription?.cancel();

    // Stop foreground service if still running
    _stopForegroundService();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // FIXED: Get current mode from _audioModes list (no 'currentMode' getter)
    final currentMode = _audioModes[_currentAudioModeIndex];

    return WillPopScope(
      onWillPop: () async {
        if (_isCapturing) {
          await _stopCaptureGracefully();
          await Future.delayed(const Duration(milliseconds: 300));
        }
        return true;
      },
      child: Scaffold(
        backgroundColor: cs.background,
        appBar: AppBar(
          title: const Text('Audio Visualizer'),
          backgroundColor: cs.surface,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _isCapturing
                ? _showExitConfirmation()
                : Navigator.of(context).pop(),
          ),
          actions: [
            if (!_isConnected) _buildDisconnectedBadge(cs),
            if (_isConnected && _isCapturing)
              IconButton(
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                onPressed: _isPaused ? _resumeCapture : _pauseCapture,
                tooltip: _isPaused ? 'Resume capture' : 'Pause capture',
              ),
          ],
        ),
        body: Column(
          children: [
            _buildModeSelector(cs),
            const SizedBox(height: 8),
            _buildStatusBanner(cs),
            const SizedBox(height: 16),
            Expanded(child: _buildVisualizerDisplay(cs)),
            const SizedBox(height: 16),
            _buildActionButtons(cs),
            _buildInfoFooter(cs),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector(ColorScheme cs) {
    // FIXED: Get current mode from _audioModes list
    final currentMode = _audioModes[_currentAudioModeIndex];

    return Container(
      color: cs.surface.withOpacity(0.9),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Audio Mode',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _audioModes[_currentAudioModeIndex].color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  currentMode.name,
                  style: TextStyle(
                    color: currentMode.color,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _audioModes.length,
              itemBuilder: (context, index) {
                final mode = _audioModes[index];
                final isActive = index == _currentAudioModeIndex;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: isActive ? mode.color.withOpacity(0.15) : null,
                      side: BorderSide(
                        color: isActive ? mode.color : cs.outline,
                        width: isActive ? 2 : 1,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isConnected ? () => _changeAudioMode(index) : null,
                    child: Row(
                      children: [
                        Icon(mode.icon, size: 18, color: isActive ? mode.color : cs.onSurface),
                        const SizedBox(width: 6),
                        Text(
                          mode.name,
                          style: TextStyle(
                            color: isActive ? mode.color : null,
                            fontSize: 13,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisconnectedBadge(ColorScheme cs) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    margin: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: Colors.red.withOpacity(0.15),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.red, width: 1),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.wifi_off, size: 16, color: Colors.red),
        const SizedBox(width: 6),
        Text('Disconnected', style: TextStyle(color: Colors.red, fontSize: 12)),
      ],
    ),
  );

  Widget _buildStatusBanner(ColorScheme cs) {
    // FIXED: Get current mode from _audioModes list
    final currentMode = _audioModes[_currentAudioModeIndex];

    return Container(
      color: _isConnected
          ? (_isCapturing
          ? (_isPaused ? Colors.orange.withOpacity(0.15) : Colors.green.withOpacity(0.15))
          : cs.primary.withOpacity(0.15))
          : Colors.red.withOpacity(0.15),
      padding: const EdgeInsets.all(14),
      child: Text(
        _status,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: _isConnected
              ? (_isCapturing
              ? (_isPaused ? Colors.orange : Colors.green)
              : cs.primary)
              : Colors.red,
          fontSize: 15,
        ),
      ),
    );
  }

  Widget _buildVisualizerDisplay(ColorScheme cs) {
    // FIXED: Get current mode from _audioModes list
    final currentMode = _audioModes[_currentAudioModeIndex];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isCapturing && !_isPaused
              ? (_isConnected ? currentMode.color : Colors.red)
              : Colors.grey,
          width: 2,
        ),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      child: _isConnected
          ? _buildVisualizerBars()
          : _buildDisconnectedVisualizer(cs),
    );
  }

  Widget _buildDisconnectedVisualizer(ColorScheme cs) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.wifi_off, size: 64, color: Colors.red.withOpacity(0.7)),
        const SizedBox(height: 16),
        Text(
          'ESP Disconnected',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red),
        ),
        const SizedBox(height: 8),
        Text(
          'Reconnect to ESP to use audio visualizer',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[400]),
        ),
      ],
    ),
  );

  Widget _buildVisualizerBars() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = (constraints.maxWidth - 40) / 16;
        final maxBarHeight = constraints.maxHeight * 0.85;

        return Column(
          children: [
            // Main bars
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(16, (index) {
                  final height = maxBarHeight * _smoothedBins[index];
                  final peakHeight = maxBarHeight * _peakHold[index];
                  final hue = index * 22.5; // Red (bass) to blue (treble)

                  return SizedBox(
                    width: barWidth,
                    child: Stack(
                      children: [
                        // Peak hold indicator (thin line at top)
                        if (_peakHold[index] > 0.1)
                          Positioned(
                            bottom: peakHeight - 2,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 2,
                              color: Colors.white.withOpacity(0.9),
                            ),
                          ),
                        // Main bar
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: barWidth * 0.85,
                            height: height,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  HSLColor.fromAHSL(1.0, hue, 1.0, 0.7).toColor(),
                                  HSLColor.fromAHSL(1.0, hue, 0.8, 0.9).toColor(),
                                ],
                              ),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
            // Mode description
            if (!_isCapturing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  // FIXED: Get current mode from _audioModes list
                  _audioModes[_currentAudioModeIndex].description,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildActionButtons(ColorScheme cs) {
    // FIXED: Get current mode from _audioModes list
    final currentMode = _audioModes[_currentAudioModeIndex];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Main action button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _isCapturing
                    ? (_isPaused ? Colors.orange : Colors.red)
                    : (_isConnected ? cs.primary : Colors.grey),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _isConnected
                  ? (_isCapturing
                  ? (_isPaused ? _resumeCapture : _stopCaptureGracefully)
                  : _startCapture)
                  : null,
              child: _isCapturing
                  ? (_isPaused
                  ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.play_arrow, size: 24),
                SizedBox(width: 8),
                Text('RESUME', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ])
                  : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.stop_circle, size: 24),
                SizedBox(width: 8),
                Text('STOP', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]))
                  : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.mic, size: 24),
                SizedBox(width: 8),
                Text('START CAPTURE', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          // Background warning
          if (_isCapturing)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 16, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '✅ Foreground service active — audio continues in background',
                      style: TextStyle(fontSize: 12, color: Colors.green),
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoFooter(ColorScheme cs) {
    // FIXED: Get current mode from _audioModes list
    final currentMode = _audioModes[_currentAudioModeIndex];

    return Container(
      padding: const EdgeInsets.all(14),
      color: cs.surface.withOpacity(0.9),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: currentMode.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Mode: ${currentMode.name}',
                style: TextStyle(
                  color: currentMode.color,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: '💡 Tips:\n',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSpan(
                  text: '• Play music/video for best results\n',
                ),
                const TextSpan(
                  text: '• Bass-heavy tracks work best for spectrum\n',
                ),
                TextSpan(
                  text: '• ${_isCapturing ? 'Tap PAUSE to conserve battery' : 'START capture to visualize audio'}',
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.primary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            '⚡ Optimized: 15fps audio streaming to prevent ESP8266 overload',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blue, fontSize: 11, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  void _showExitConfirmation() => showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Stop Audio Capture?'),
      content: Text(
        _isPaused
            ? 'You have a paused capture session. Stop completely?'
            : 'You are currently capturing audio. Stop capture before leaving?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton.tonal(
          onPressed: () {
            Navigator.of(context).pop();
            _stopCaptureGracefully().then((_) {
              if (mounted) Navigator.of(context).pop();
            });
          },
          child: const Text('STOP & EXIT'),
        ),
      ],
    ),
  );
}

// ===== AUDIO MODE CONFIGURATION =====
class AudioModeConfig {
  final int mode;
  final String name;
  final IconData icon;
  final Color color;
  final String description;

  const AudioModeConfig({
    required this.mode,
    required this.name,
    required this.icon,
    required this.color,
    required this.description,
  });
}

// ===== FOREGROUND TASK HANDLER =====
// This is a lightweight callback — the actual audio processing stays in the widget.
// Its only job is to keep the foreground service alive.
@pragma('vm:entry-point')
class AudioCaptureTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('[FG_SERVICE] Audio capture foreground service started');
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    FlutterForegroundTask.updateService(
      notificationTitle: '🎵 Audio Visualizer Active',
      notificationText: 'Streaming audio to ESP LEDs',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('[FG_SERVICE] Audio capture foreground service destroyed');
  }

  @override
  void onReceiveData(Object data) {
    // Receive commands from UI if needed
    if (data == 'pause') {
      FlutterForegroundTask.updateService(
        notificationTitle: '⏸️ Audio Visualizer Paused',
        notificationText: 'Tap to resume',
      );
    } else if (data == 'resume') {
      FlutterForegroundTask.updateService(
        notificationTitle: '🎵 Audio Visualizer Active',
        notificationText: 'Streaming audio to ESP LEDs',
      );
    }
  }
}