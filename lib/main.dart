import 'package:flutter/material.dart';

void main() => runApp(const ClipboardApp());

class ClipboardApp extends StatelessWidget {
  const ClipboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexaClip',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ClipboardHomePage(),
    );
  }
}

class ClipboardHomePage extends StatelessWidget {
  const ClipboardHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NexaClip')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Ứng dụng đang được xây dựng. Lịch sử clipboard chưa được lưu.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
