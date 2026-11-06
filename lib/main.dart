import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(700, 380),
    minimumSize: Size(700, 380),
    maximumSize: Size(700, 380),
    center: true,
    title: "Repomix Portable Clone",
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Repomix Clone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121316),
        primaryColor: const Color(0xFFFF6B00),
        cardColor: const Color(0xFF1A1B1F),
        hintColor: const Color(0xFFA0A0A0),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedInputType = 1; // 0: 連結, 1: 資料夾, 2: 壓縮包
  String _selectedPathOrUrl = '';
  String _displayPath = '點擊或拖放本地專案資料夾至此...';
  String _outputFormat = 'Markdown';
  bool _includeSummary = true;
  bool _includeStructure = true;
  String _statusMessage = '就緒。支援拖放資料夾或 ZIP 壓縮包。';
  bool _isProcessing = false;
  bool _isDragging = false;

  void _updateDisplayPlaceholder() {
    if (_selectedInputType == 0) {
      _displayPath = _selectedPathOrUrl.isEmpty
          ? '請輸入 GitHub 倉庫克隆連結...'
          : _selectedPathOrUrl;
    } else if (_selectedInputType == 1) {
      _displayPath = _selectedPathOrUrl.isEmpty
          ? '點擊或拖放本地專案資料夾至此...'
          : p.basename(_selectedPathOrUrl);
    } else {
      _displayPath = _selectedPathOrUrl.isEmpty
          ? '點擊或拖放本地專案 .zip 檔案至此...'
          : p.basename(_selectedPathOrUrl);
    }
  }

  String _getExpectedExtension() {
    if (_outputFormat == 'XML') return 'xml';
    if (_outputFormat == 'Markdown') return 'md';
    return 'txt';
  }

  Future<void> _handlePathSelection() async {
    if (_selectedInputType == 1) {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '選擇專案資料夾',
      );
      if (dir != null) {
        setState(() {
          _selectedPathOrUrl = dir;
          _updateDisplayPlaceholder();
        });
      }
    } else if (_selectedInputType == 2) {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (res != null && res.files.single.path != null) {
        setState(() {
          _selectedPathOrUrl = res.files.single.path!;
          _updateDisplayPlaceholder();
        });
      }
    } else {
      _showUrlDialog();
    }
  }

  void _showUrlDialog() {
    final controller = TextEditingController(text: _selectedPathOrUrl);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('輸入 Git 倉庫連結'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'https://github.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _selectedPathOrUrl = controller.text;
                _updateDisplayPlaceholder();
              });
              Navigator.pop(ctx);
            },
            child: const Text('確定'),
          ),
        ],
      ),
    );
  }

  Future<void> _startPacking() async {
    if (_selectedPathOrUrl.isEmpty) return;

    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: '儲存打包結果',
      fileName: 'codebase.${_getExpectedExtension()}',
      type: FileType.custom,
      allowedExtensions: [_getExpectedExtension()],
    );

    if (outputPath == null) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = '正在打包中...';
    });

    try {
      String target = _selectedPathOrUrl;
      Directory? tempDirectory;

      if (_selectedInputType == 2) {
        tempDirectory = Directory(p.join(Directory.systemTemp.path, 'repomix_extracted'));
        if (tempDirectory.existsSync()) {
          tempDirectory.deleteSync(recursive: true);
        }
        tempDirectory.createSync(recursive: true);

        final bytes = File(_selectedPathOrUrl).readAsBytesSync();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          if (file.isFile) {
            final outputFile = File(p.join(tempDirectory.path, file.name));
            outputFile.createSync(recursive: true);
            outputFile.writeAsBytesSync(file.content as List<int>);
          }
        }

        target = tempDirectory.path;
      } else if (_selectedInputType == 0) {
        tempDirectory = Directory(p.join(Directory.systemTemp.path, 'repomix_git'));
        if (tempDirectory.existsSync()) {
          tempDirectory.deleteSync(recursive: true);
        }

        final res = await Process.run(
          'git',
          ['clone', '--depth', '1', _selectedPathOrUrl, tempDirectory.path],
        );

        if (res.exitCode != 0) {
          throw Exception('Git Clone 失敗');
        }

        target = tempDirectory.path;
      }

      final buffer = StringBuffer();
      final sourceDir = Directory(target);
      const ignore = ['.git', 'node_modules', 'build', 'dist', '.png', '.jpg', '.zip', '.exe'];

      final entities = sourceDir.listSync(recursive: true);
      final files = <File>[];

      for (final entity in entities) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: target);
          final fileName = p.basename(relativePath);

          final shouldIgnore = ignore.any(
            (pattern) => relativePath.contains(pattern) || fileName.startsWith('.'),
          );

          if (!shouldIgnore) {
            files.add(entity);
          }
        }
      }

      files.sort((a, b) => a.path.compareTo(b.path));

      if (_includeStructure) {
        buffer.writeln('=== DIRECTORY STRUCTURE ===');
        for (final file in files) {
          buffer.writeln('- ${p.relative(file.path, from: target).replaceAll('\\', '/')}');
        }
        buffer.writeln('===========================\n');
      }

      if (_includeSummary) {
        buffer.writeln('=== FILE SUMMARY ===');
        for (final file in files) {
          buffer.writeln('Path: ${p.relative(file.path, from: target).replaceAll('\\', '/')}');
        }
        buffer.writeln('====================\n');
      }

      buffer.writeln('=== CODEBASE CONTENT ===\n');

      for (final file in files) {
        final relativePath = p.relative(file.path, from: target).replaceAll('\\', '/');
        String text = '';

        try {
          text = file.readAsStringSync(encoding: utf8);
        } catch (_) {
          continue;
        }

        if (_outputFormat == 'XML') {
          buffer.writeln('\n$text\n\n');
        } else if (_outputFormat == 'Markdown') {
          final ext = p.extension(file.path).replaceAll('.', '');
          buffer.writeln('### File: $relativePath\n$ext\n$text\n\n');
        } else {
          buffer.writeln('--- START: $relativePath ---\n$text\n--- END ---\n');
        }
      }

      await File(outputPath).writeAsString(buffer.toString());

      if (tempDirectory != null && tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }

      setState(() {
        _statusMessage = '🎉 打包成功！已儲存至：${p.basename(outputPath)}';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = '❌ 錯誤：$e';
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Container(
          width: 660,
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Repomix',
                style: TextStyle(
                  color: theme.primaryColor,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Pack your codebase into AI-friendly formats',
                style: TextStyle(color: theme.hintColor, fontSize: 13),
              ),
              const SizedBox(height: 20),
              DropTarget(
                onDragEntered: (_) => setState(() => _isDragging = true),
                onDragExited: (_) => setState(() => _isDragging = false),
                onDragDone: (details) {
                  setState(() {
                    _isDragging = false;
                  });

                  if (details.files.isNotEmpty) {
                    final path = details.files.first.path;
                    setState(() {
                      _selectedPathOrUrl = path;
                      _selectedInputType = path.endsWith('.zip') ? 2 : 1;
                      _updateDisplayPlaceholder();
                    });
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: _isDragging ? const Color(0xFF25272C) : theme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _isDragging ? theme.primaryColor : const Color(0xFF2D2F34),
                      width: 1,
                    ),
                  ),
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          ToggleButtons(
                            isSelected: [
                              _selectedInputType == 0,
                              _selectedInputType == 1,
                              _selectedInputType == 2,
                            ],
                            onPressed: (idx) {
                              setState(() {
                                _selectedInputType = idx;
                                _selectedPathOrUrl = '';
                                _updateDisplayPlaceholder();
                              });
                            },
                            fillColor: theme.primaryColor,
                            selectedColor: Colors.white,
                            color: theme.hintColor,
                            borderRadius: BorderRadius.circular(6),
                            constraints: const BoxConstraints(minWidth: 45, minHeight: 36),
                            children: const [
                              Icon(Icons.link, size: 16),
                              Icon(Icons.folder_open, size: 16),
                              Icon(Icons.inventory_2, size: 16),
                            ],
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: _isProcessing ? null : _handlePathSelection,
                              child: Container(
                                height: 36,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  border: Border.all(color: const Color(0xFF40434A)),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _displayPath,
                                  style: TextStyle(
                                    color: _selectedPathOrUrl.isEmpty
                                        ? theme.hintColor
                                        : theme.primaryColor,
                                    fontSize: 12,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: _isProcessing ? null : _startPacking,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.primaryColor,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(80, 36),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            child: const Text(
                              'Pack',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 5),
                          IconButton(
                            onPressed: () {
                              setState(() {
                                _selectedPathOrUrl = '';
                                _updateDisplayPlaceholder();
                                _statusMessage = '狀態已重置。';
                              });
                            },
                            icon: const Icon(Icons.refresh, size: 18),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF2D2F34),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              minimumSize: const Size(36, 36),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Output Format',
                                style: TextStyle(color: theme.hintColor, fontSize: 11),
                              ),
                              const SizedBox(height: 5),
                              ToggleButtons(
                                isSelected: [
                                  _outputFormat == 'XML',
                                  _outputFormat == 'Markdown',
                                  _outputFormat == 'Plain',
                                ],
                                onPressed: (idx) {
                                  final formats = ['XML', 'Markdown', 'Plain'];
                                  setState(() => _outputFormat = formats[idx]);
                                },
                                fillColor: theme.primaryColor,
                                selectedColor: Colors.white,
                                color: theme.hintColor,
                                borderRadius: BorderRadius.circular(6),
                                constraints: const BoxConstraints(minWidth: 70, minHeight: 30),
                                children: const [
                                  Text('XML', style: TextStyle(fontSize: 11)),
                                  Text('Markdown', style: TextStyle(fontSize: 11)),
                                  Text('Plain', style: TextStyle(fontSize: 11)),
                                ],
                              ),
                            ],
                          ),
                          const Spacer(),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Output Format Options',
                                style: TextStyle(color: theme.hintColor, fontSize: 11),
                              ),
                              Row(
                                children: [
                                  SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: Checkbox(
                                      value: _includeSummary,
                                      activeColor: theme.primaryColor,
                                      onChanged: (v) =>
                                          setState(() => _includeSummary = v ?? true),
                                    ),
                                  ),
                                  const Text(
                                    ' Include File Summary',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: Checkbox(
                                      value: _includeStructure,
                                      activeColor: theme.primaryColor,
                                      onChanged: (v) =>
                                          setState(() => _includeStructure = v ?? true),
                                    ),
                                  ),
                                  const Text(
                                    ' Include Directory Structure',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 15),
              Text(
                _statusMessage,
                style: const TextStyle(
                  color: Color(0xFF606060),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
