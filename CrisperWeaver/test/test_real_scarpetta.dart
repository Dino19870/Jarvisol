// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:jarvisol/services/document_source_service.dart';
import 'package:http/http.dart' as http;

void main() async {
  final path =
      r"C:\Users\lansa\OneDrive\Olivier-IA\Desktop\Kay Scarpetta 01 - Postmortem - Patricia Cornwell.epub";
  final service = DocumentSourceService();
  final item = await service.parseFile(path);

  // Take first 20,000 characters
  final contextText = item.textContent.substring(
      0, item.textContent.length > 20000 ? 20000 : item.textContent.length);

  final prompt =
      """Tu es un assistant expert. Voici les premiers chapitres du livre :
---
$contextText
---
Question : D'après les chapitres fournis ci-dessus, nomme précisément tous les personnages qui apparaissent ou sont mentionnés, en indiquant leur rôle ou leur lien avec l'héroïne.""";

  final body = jsonEncode({
    'model': 'gemma-4-12B-it-gpu',
    'messages': [
      {'role': 'user', 'content': prompt}
    ],
    'max_tokens': 1024,
    'temperature': 0.7,
    'stream': false,
  });

  final res = await http.post(
    Uri.parse('http://localhost:9379/v1/chat/completions'),
    headers: {'Content-Type': 'application/json'},
    body: body,
  );

  final data = jsonDecode(res.body);
  print(data['choices'][0]['message']['content']);
}
