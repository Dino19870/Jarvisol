// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

void main() async {
  final client = HttpClient();
  try {
    final bytes = utf8.encode(jsonEncode({
      'model': 'qwen-2.5-1.5b-instruct',
      'messages': [
        {'role': 'system', 'content': 'Tu es un assistant IA.'},
        {'role': 'user', 'content': 'Qui est Kay ?'}
      ],
      'temperature': 0.7,
      'stream': true,
      'max_tokens': 500,
    }));

    final req = await client
        .postUrl(Uri.parse('http://127.0.0.1:9379/v1/chat/completions'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.headers.set('Accept', 'text/event-stream, */*');
    req.contentLength = bytes.length;
    req.add(bytes);

    final res = await req.close();
    print('HTTP Status: ' + res.statusCode.toString());

    await for (final line
        in res.transform(utf8.decoder).transform(const LineSplitter())) {
      print('Line: ' + line);
    }
  } catch (e, st) {
    print('Dart Exception: ' + e.toString());
  } finally {
    client.close();
  }
}
