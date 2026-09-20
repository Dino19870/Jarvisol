
import 'dart:io';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:path/path.dart' as p;

void main() async {
  final tempDir = await Directory.systemTemp.createTemp('path_comp_');
  AppPaths.setTestOverride(tempDir);
  final tempVoicesDir = AppPaths.importedVoicesDir;

  final f1 = File('\/PPDA_Qwen3.gguf');
  await f1.writeAsBytes([1, 2, 3]);

  final f2 = File(p.join(AppPaths.importedVoicesDir.path, 'PPDA_Qwen3.gguf'));
  print('f1 path: ' + f1.path);
  print('f1 exists: ' + f1.existsSync().toString());
  print('f2 path: ' + f2.path);
  print('f2 exists: ' + f2.existsSync().toString());

  AppPaths.resetTestOverride();
  tempDir.deleteSync(recursive: true);
}
