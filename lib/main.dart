import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

// ==================== 全局常量与轻量哈希汇聚器 ====================
const int kHttpPort = 8848;
const int kDiscoveryPort = 8849;
const String kProtocolMagic = "LANDROP_PING";

// 用于无内存压力的流式 Hash 校验 Sink
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanDropApp());
}

// ==================== 主入口 UI ====================
class LanDropApp extends StatelessWidget {
  const LanDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LanDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

// ==================== 数据模型 ====================
class DeviceInfo {
  final String ip;
  final int port;
  final String name;
  final String os;
  DateTime lastSeen;

  DeviceInfo({
    required this.ip,
    required this.port,
    required this.name,
    required this.os,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'ip': ip,
    'port': port,
    'name': name,
    'os': os,
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    ip: json['ip'] ?? '',
    port: json['port'] ?? kHttpPort,
    name: json['name'] ?? 'Unknown',
    os: json['os'] ?? 'Unknown',
    lastSeen: DateTime.now(),
  );
}

class TransferTask {
  final String id;
  final String fileName;
  final int totalBytes;
  int currentBytes;
  double speed; // KB/s
  bool isUploading;
  bool isDone;
  String? error;

  TransferTask({
    required this.id,
    required this.fileName,
    required this.totalBytes,
    this.currentBytes = 0,
    this.speed = 0.0,
    required this.isUploading,
    this.isDone = false,
    this.error,
  });
}

// ==================== 核心后端引擎 (Engine) ====================
class LanEngine extends ChangeNotifier {
  String localIp = '127.0.0.1';
  String deviceName = Platform.localHostname;
  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;

  final Map<String, DeviceInfo> discoveredDevices = {};
  final List<TransferTask> activeTasks = [];
  final List<File> webSharedFiles = [];
  final List<String> receivedMessages = [];

  bool isServerRunning = false;

  Future<void> startEngine() async {
    await _detectLocalIp();
    await _startHttpServer();
    await _startUdpDiscovery();
    notifyListeners();
  }

  // 1. 获取物理网络 IPv4
  Future<void> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (var iface in interfaces) {
        if (!iface.name.toLowerCase().contains('vmware') &&
            !iface.name.toLowerCase().contains('virtual') &&
            !iface.name.toLowerCase().contains('wsl')) {
          for (var addr in iface.addresses) {
            if (!addr.isLoopback) {
              localIp = addr.address;
              return;
            }
          }
        }
      }
    } catch (e) {
      debugPrint("获取IP失败: $e");
    }
  }

  // 2. 内嵌 HTTP 服务
  Future<void> _startHttpServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, kHttpPort);
      isServerRunning = true;
      _server!.listen(_handleHttpRequest);
    } catch (e) {
      debugPrint("启动HTTP服务异常: $e");
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;

    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    try {
      if (path == '/' || path == '/index.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_generateWebPortalHtml());
        await request.response.close();
        return;
      }

      if (path == '/api/shared-files') {
        final list = webSharedFiles.map((f) => {
          'name': p.basename(f.path),
          'size': f.lengthSync(),
        }).toList();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(list));
        await request.response.close();
        return;
      }

      // Range 断点续传流式下载
      if (path.startsWith('/download/')) {
        final index = int.tryParse(path.replaceFirst('/download/', ''));
        if (index != null && index >= 0 && index < webSharedFiles.length) {
          final file = webSharedFiles[index];
          await _serveFileWithRange(request, file);
          return;
        }
      }

      if (path == '/api/message' && request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        final json = jsonDecode(content);
        receivedMessages.insert(0, "${json['sender']}: ${json['text']}");
        notifyListeners();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      // 接收大文件流式上传 (零内存溢出)
      if (path == '/api/upload' && request.method == 'POST') {
        await _handleIncomingStreamUpload(request);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      debugPrint("HTTP 请求处理异常: $e");
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  // 大文件流式下载 + Range 支持 (已修复：直接使用 file.openRead)
  Future<void> _serveFileWithRange(HttpRequest request, File file) async {
    final fileSize = await file.length();
    final rangeHeader = request.headers.value('range');

    request.response.headers.add('Accept-Ranges', 'bytes');
    request.response.headers.add(
      'Content-Disposition',
      'attachment; filename="${Uri.encodeComponent(p.basename(file.path))}"',
    );

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      final start = int.parse(parts[0]);
      final end = (parts.length > 1 && parts[1].isNotEmpty) ? int.parse(parts[1]) : fileSize - 1;

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.add('Content-Range', 'bytes $start-$end/$fileSize');
      request.response.contentLength = (end - start) + 1;

      // 直接通过 File 的 openRead 切片流式输出
      await request.response.addStream(file.openRead(start, end + 1));
    } else {
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = fileSize;
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
  }

  // 流式接收处理 (已修复：使用纯原生 _DigestSink)
  Future<void> _handleIncomingStreamUpload(HttpRequest request) async {
    final fileName = Uri.decodeComponent(
      request.headers.value('X-File-Name') ?? 'unnamed_${DateTime.now().millisecondsSinceEpoch}.bin',
    );
    final relativePath = Uri.decodeComponent(request.headers.value('X-Relative-Path') ?? '');
    final totalSize = int.tryParse(request.headers.value('X-File-Size') ?? '0') ?? 0;
    final expectedHash = request.headers.value('X-Checksum');
    final resumeOffset = int.tryParse(request.headers.value('X-Resume-Offset') ?? '0') ?? 0;

    final downloadDir = await _getSafeDownloadDirectory();
    final targetDir = relativePath.isNotEmpty ? Directory(p.join(downloadDir.path, p.dirname(relativePath))) : downloadDir;
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final finalFile = File(p.join(downloadDir.path, relativePath.isNotEmpty ? relativePath : fileName));
    final mode = resumeOffset > 0 ? FileMode.append : FileMode.write;
    final raf = await finalFile.open(mode: mode);

    final task = TransferTask(
      id: DateTime.now().toIso8601String(),
      fileName: relativePath.isNotEmpty ? relativePath : fileName,
      totalBytes: totalSize,
      currentBytes: resumeOffset,
      isUploading: false,
    );
    activeTasks.insert(0, task);
    notifyListeners();

    int lastBytes = resumeOffset;
    DateTime lastTime = DateTime.now();

    final digestSink = _DigestSink();
    final md5Input = md5.startChunkedConversion(digestSink);

    try {
      await for (final chunk in request) {
        await raf.writeFrom(chunk);
        md5Input.add(chunk);
        task.currentBytes += chunk.length;

        final now = DateTime.now();
        final ms = now.difference(lastTime).inMilliseconds;
        if (ms >= 500) {
          task.speed = ((task.currentBytes - lastBytes) / 1024) / (ms / 1000);
          lastBytes = task.currentBytes;
          lastTime = now;
          notifyListeners();
        }
      }
      await raf.close();
      md5Input.close();

      task.isDone = true;
      task.speed = 0;

      if (expectedHash != null && resumeOffset == 0 && digestSink.value != null) {
        if (digestSink.value.toString().toLowerCase() != expectedHash.toLowerCase()) {
          task.error = "MD5 校验不匹配";
        }
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.write("OK");
    } catch (e) {
      task.error = e.toString();
      await raf.close();
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
      notifyListeners();
    }
  }

  // 3. UDP 设备发现机制
  Future<void> _startUdpDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data);
              if (text.startsWith(kProtocolMagic)) {
                final jsonStr = text.replaceFirst('$kProtocolMagic:', '');
                final data = jsonDecode(jsonStr);
                final dev = DeviceInfo.fromJson(data);

                if (dev.ip != localIp) {
                  discoveredDevices[dev.ip] = dev;
                  notifyListeners();
                }
              }
            } catch (_) {}
          }
        }
      });

      _broadcastTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _broadcastSelf();
      });
    } catch (e) {
      debugPrint("UDP广播失败: $e");
    }
  }

  void _broadcastSelf() {
    if (_udpSocket == null) return;
    try {
      final info = DeviceInfo(
        ip: localIp,
        port: kHttpPort,
        name: deviceName,
        os: Platform.operatingSystem,
        lastSeen: DateTime.now(),
      );
      final payload = utf8.encode("$kProtocolMagic:${jsonEncode(info.toJson())}");
      _udpSocket!.send(payload, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } catch (_) {}
  }

  // 4. 客户端主动发文件 (流式传输，零内存溢出)
  Future<void> sendFiles(DeviceInfo target, List<String> paths) async {
    final client = HttpClient();

    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        final dir = Directory(path);
        final baseName = p.basename(dir.path);
        final entities = dir.listSync(recursive: true);

        for (final entity in entities) {
          if (entity is File) {
            final rel = p.join(baseName, p.relative(entity.path, from: dir.path));
            await _sendFileStream(client, target, entity, relativePath: rel);
          }
        }
      } else {
        await _sendFileStream(client, target, File(path));
      }
    }
    client.close();
  }

  Future<void> _sendFileStream(HttpClient client, DeviceInfo target, File file, {String? relativePath}) async {
    final totalSize = await file.length();
    final fileName = p.basename(file.path);

    final task = TransferTask(
      id: DateTime.now().toIso8601String(),
      fileName: relativePath ?? fileName,
      totalBytes: totalSize,
      isUploading: true,
    );
    activeTasks.insert(0, task);
    notifyListeners();

    try {
      final req = await client.post(target.ip, target.port, '/api/upload');
      req.headers.add('X-File-Name', Uri.encodeComponent(fileName));
      req.headers.add('X-File-Size', totalSize.toString());
      if (relativePath != null) {
        req.headers.add('X-Relative-Path', Uri.encodeComponent(relativePath));
      }

      int lastBytes = 0;
      DateTime lastTime = DateTime.now();

      final stream = file.openRead();
      await req.addStream(
        stream.map((chunk) {
          task.currentBytes += chunk.length;
          final now = DateTime.now();
          final ms = now.difference(lastTime).inMilliseconds;
          if (ms >= 500) {
            task.speed = ((task.currentBytes - lastBytes) / 1024) / (ms / 1000);
            lastBytes = task.currentBytes;
            lastTime = now;
            notifyListeners();
          }
          return chunk;
        }),
      );

      final res = await req.close();
      if (res.statusCode == HttpStatus.ok) {
        task.isDone = true;
      } else {
        task.error = "远端返回错误: ${res.statusCode}";
      }
    } catch (e) {
      task.error = e.toString();
    } finally {
      task.speed = 0;
      notifyListeners();
    }
  }

  // 5. 快速发送文本
  Future<void> sendMessage(DeviceInfo target, String text) async {
    try {
      final client = HttpClient();
      final req = await client.post(target.ip, target.port, '/api/message');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'sender': deviceName, 'text': text}));
      await req.close();
      client.close();
    } catch (e) {
      debugPrint("发送文本失败: $e");
    }
  }

  Future<Directory> _getSafeDownloadDirectory() async {
    if (Platform.isAndroid) {
      return (await getExternalStorageDirectory()) ?? (await getApplicationDocumentsDirectory());
    } else {
      return (await getDownloadsDirectory()) ?? Directory.current;
    }
  }

  String _generateWebPortalHtml() {
    return '''
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>LanDrop Web Portal</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 20px; background: #f4f6f8; color: #333; }
        .card { max-width: 600px; margin: 0 auto 20px auto; background: #fff; padding: 24px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        h2 { margin-top: 0; color: #4F46E5; }
        .file-item { display: flex; justify-content: space-between; align-items: center; padding: 12px; border-bottom: 1px solid #eee; }
        .btn { background: #4F46E5; color: #fff; padding: 8px 16px; border-radius: 6px; text-decoration: none; border: none; cursor: pointer; }
      </style>
    </head>
    <body>
      <div class="card">
        <h2>🚀 LanDrop 免安装共享</h2>
        <p>来自 <strong>$deviceName</strong> ($localIp) 的直传服务</p>
      </div>
      <div class="card">
        <h3>📥 下载共享文件</h3>
        <div id="file-list">加载中...</div>
      </div>
      <script>
        fetch('/api/shared-files')
          .then(res => res.json())
          .then(files => {
            const container = document.getElementById('file-list');
            if (files.length === 0) {
              container.innerHTML = '<p style="color:#888;">暂无待下载的文件</p>';
              return;
            }
            container.innerHTML = files.map((f, i) => `
              <div class="file-item">
                <span>\${f.name} (\${(f.size/1024/1024).toFixed(2)} MB)</span>
                <a class="btn" href="/download/\${i}">高速下载</a>
              </div>
            `).join('');
          });
      </script>
    </body>
    </html>
    ''';
  }

  @override
  void dispose() {
    _broadcastTimer?.cancel();
    _udpSocket?.close();
    _server?.close(force: true);
    super.dispose();
  }
}

// ==================== 主页面 UI (Tab 布局) ====================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final LanEngine engine = LanEngine();
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    engine.startEngine();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text("LanDrop - ${engine.deviceName} (${engine.localIp})"),
            actions: [
              IconButton(
                icon: const Icon(Icons.qr_code),
                tooltip: "本机二维码",
                onPressed: () => _showQrModal(context, "http://${engine.localIp}:$kHttpPort"),
              ),
              if (Platform.isAndroid)
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: "扫码连接",
                  onPressed: () => _openScanner(context),
                ),
            ],
          ),
          body: IndexedStack(
            index: _currentIndex,
            children: [
              _buildPeersTab(),
              _buildTransfersTab(),
              _buildWebShareTab(),
              _buildMessagesTab(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.devices), label: '对端设备'),
              NavigationDestination(icon: Icon(Icons.swap_vert), label: '传输队列'),
              NavigationDestination(icon: Icon(Icons.cloud_upload_outlined), label: '网页快传'),
              NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: '文本消息'),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPeersTab() {
    final devices = engine.discoveredDevices.values.toList();
    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text("正在搜索局域网设备 (端口 $kDiscoveryPort)..."),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _showManualConnectDialog(context),
              child: const Text("手动输入 IP 直连"),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final dev = devices[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            leading: Icon(
              dev.os.toLowerCase().contains('windows') ? Icons.laptop_windows : Icons.phone_android,
              size: 36,
            ),
            title: Text(dev.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text("${dev.ip}:${dev.port} | 系统: ${dev.os}"),
            trailing: PopupMenuButton<String>(
              onSelected: (val) async {
                if (val == 'file') {
                  final result = await FilePicker.platform.pickFiles(allowMultiple: true);
                  if (result != null) {
                    engine.sendFiles(dev, result.paths.whereType<String>().toList());
                  }
                } else if (val == 'folder') {
                  final dirPath = await FilePicker.platform.getDirectoryPath();
                  if (dirPath != null) {
                    engine.sendFiles(dev, [dirPath]);
                  }
                } else if (val == 'clipboard') {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    engine.sendMessage(dev, data!.text!);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已推送剪贴板文本")));
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'file', child: Text('发送文件')),
                const PopupMenuItem(value: 'folder', child: Text('发送整个文件夹')),
                const PopupMenuItem(value: 'clipboard', child: Text('推送剪贴板')),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTransfersTab() {
    if (engine.activeTasks.isEmpty) {
      return const Center(child: Text("当前无传输任务"));
    }
    return ListView.builder(
      itemCount: engine.activeTasks.length,
      itemBuilder: (context, index) {
        final task = engine.activeTasks[index];
        final progress = task.totalBytes > 0 ? (task.currentBytes / task.totalBytes).clamp(0.0, 1.0) : 0.0;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        "${task.isUploading ? '⬆ 发送' : '⬇ 接收'}: ${task.fileName}",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(task.isDone ? "已完成" : "${task.speed.toStringAsFixed(1)} KB/s"),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: task.isDone ? 1.0 : progress),
                const SizedBox(height: 4),
                Text(
                  "${(task.currentBytes / 1024 / 1024).toStringAsFixed(2)} MB / ${(task.totalBytes / 1024 / 1024).toStringAsFixed(2)} MB",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (task.error != null)
                  Text("错误: ${task.error}", style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWebShareTab() {
    final webUrl = "http://${engine.localIp}:$kHttpPort";
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              QrImageView(data: webUrl, size: 80),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("网页端直传已就绪", style: TextStyle(fontWeight: FontWeight.bold)),
                    SelectableText(webUrl, style: const TextStyle(color: Colors.deepPurple)),
                    const Text("同局域网任何浏览器扫码/访问即可直接下载文件", style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("添加分享文件"),
            onPressed: () async {
              final result = await FilePicker.platform.pickFiles(allowMultiple: true);
              if (result != null) {
                for (var p in result.paths.whereType<String>()) {
                  engine.webSharedFiles.add(File(p));
                }
                engine.notifyListeners();
              }
            },
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: engine.webSharedFiles.length,
            itemBuilder: (context, i) {
              final f = engine.webSharedFiles[i];
              return ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: Text(p.basename(f.path)),
                subtitle: Text("${(f.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB"),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    engine.webSharedFiles.removeAt(i);
                    engine.notifyListeners();
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMessagesTab() {
    final controller = TextEditingController();
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            itemCount: engine.receivedMessages.length,
            itemBuilder: (context, i) {
              final msg = engine.receivedMessages[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  title: SelectableText(msg),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: msg));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已复制到剪贴板")));
                    },
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: "广播文本到局域网...",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send),
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    for (var dev in engine.discoveredDevices.values) {
                      engine.sendMessage(dev, controller.text);
                    }
                    controller.clear();
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showQrModal(BuildContext context, String data) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("扫码快速连接"),
        content: SizedBox(
          width: 240,
          height: 240,
          child: Center(child: QrImageView(data: data, size: 220)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("关闭")),
        ],
      ),
    );
  }

  void _showManualConnectDialog(BuildContext context) {
    final ipController = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("手动连接目标设备"),
        content: TextField(
          controller: ipController,
          decoration: const InputDecoration(hintText: "例如: 192.168.1.100"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              final ip = ipController.text.trim();
              if (ip.isNotEmpty) {
                engine.discoveredDevices[ip] = DeviceInfo(
                  ip: ip,
                  port: kHttpPort,
                  name: "手动设备 ($ip)",
                  os: "Unknown",
                  lastSeen: DateTime.now(),
                );
                engine.notifyListeners();
                Navigator.pop(context);
              }
            },
            child: const Text("添加"),
          ),
        ],
      ),
    );
  }

  void _openScanner(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text("扫描目标设备二维码")),
          body: MobileScanner(
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  final raw = barcode.rawValue!;
                  Uri? uri = Uri.tryParse(raw);
                  if (uri != null && uri.host.isNotEmpty) {
                    engine.discoveredDevices[uri.host] = DeviceInfo(
                      ip: uri.host,
                      port: uri.port != 0 ? uri.port : kHttpPort,
                      name: "扫码设备",
                      os: "Remote",
                      lastSeen: DateTime.now(),
                    );
                    engine.notifyListeners();
                    Navigator.pop(context);
                    break;
                  }
                }
              }
            },
          ),
        ),
      ),
    );
  }
}
