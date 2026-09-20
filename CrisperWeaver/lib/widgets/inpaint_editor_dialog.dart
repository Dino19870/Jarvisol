import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

enum _ToolMode { brush, eraser, rectangle, lasso, pan }

enum _OpType { brush, rect, poly }

class _MaskOp {
  final _OpType opType;
  final bool erase;
  final List<Offset> points;
  final double brushSize;
  final Rect? rect;

  const _MaskOp._({
    required this.opType,
    required this.erase,
    required this.points,
    required this.brushSize,
    this.rect,
  });

  factory _MaskOp.brush(List<Offset> pts, double sz, {bool erase = false}) =>
      _MaskOp._(
          opType: _OpType.brush, erase: erase, points: pts, brushSize: sz);

  factory _MaskOp.rectangle(Rect r, {bool erase = false}) =>
      _MaskOp._(
          opType: _OpType.rect, erase: erase, points: [], brushSize: 0, rect: r);

  factory _MaskOp.polygon(List<Offset> poly, {bool erase = false}) =>
      _MaskOp._(
          opType: _OpType.poly, erase: erase, points: poly, brushSize: 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter
// ─────────────────────────────────────────────────────────────────────────────

class _MaskPainter extends CustomPainter {
  final List<_MaskOp> ops;
  final _MaskOp? activeOp;       // brush/eraser en cours
  final List<Offset> lassoPts;   // polygone en cours (non validé)
  final Offset? lassoMouse;      // position curseur pour aperçu lasso
  final Rect? rectPreview;       // rectangle en cours
  final bool rectErase;

  const _MaskPainter({
    required this.ops,
    this.activeOp,
    this.lassoPts = const [],
    this.lassoMouse,
    this.rectPreview,
    this.rectErase = false,
  });

  static void _paintOp(Canvas c, _MaskOp op, {bool forExport = false}) {
    Paint makePaint(bool erase) {
      if (forExport) {
        return Paint()
          ..color = erase ? Colors.black : Colors.white
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
      }
      if (erase) {
        return Paint()
          ..blendMode = BlendMode.clear
          ..isAntiAlias = true;
      }
      return Paint()
        ..color = Colors.white.withValues(alpha: 0.65)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
    }

    final p = makePaint(op.erase);
    final lineP = forExport
        ? (Paint()
          ..color = op.erase ? Colors.black : Colors.white
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke)
        : (Paint()
          ..color = op.erase ? Colors.white : Colors.white.withValues(alpha: 0.65)
          ..blendMode = op.erase ? BlendMode.clear : BlendMode.srcOver
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true);

    switch (op.opType) {
      case _OpType.brush:
        lineP.strokeWidth = op.brushSize;
        for (int i = 0; i < op.points.length; i++) {
          c.drawCircle(op.points[i], op.brushSize / 2, p);
          if (i > 0) c.drawLine(op.points[i - 1], op.points[i], lineP);
        }

      case _OpType.rect:
        if (op.rect != null) {
          c.drawRect(op.rect!, p);
        }

      case _OpType.poly:
        if (op.points.length < 2) return;
        final path = Path()
          ..moveTo(op.points.first.dx, op.points.first.dy);
        for (final pt in op.points.skip(1)) path.lineTo(pt.dx, pt.dy);
        path.close();
        c.drawPath(path, p..style = PaintingStyle.fill);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer pour que BlendMode.clear fonctionne correctement
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());

    for (final op in ops) {
      _paintOp(canvas, op);
    }
    if (activeOp != null) _paintOp(canvas, activeOp!);

    // Aperçu rectangle en cours
    if (rectPreview != null) {
      canvas.drawRect(
        rectPreview!,
        Paint()
          ..color = (rectErase ? Colors.redAccent : Colors.white)
              .withValues(alpha: 0.35)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        rectPreview!,
        Paint()
          ..color = rectErase ? Colors.redAccent : Colors.orangeAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Aperçu lasso en cours
    if (lassoPts.isNotEmpty) {
      final dotPaint = Paint()
        ..color = Colors.orangeAccent
        ..style = PaintingStyle.fill;
      final linePaint = Paint()
        ..color = Colors.orangeAccent.withValues(alpha: 0.8)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      for (int i = 0; i < lassoPts.length; i++) {
        canvas.drawCircle(lassoPts[i], 4, dotPaint);
        if (i > 0) canvas.drawLine(lassoPts[i - 1], lassoPts[i], linePaint);
      }
      // Ligne dynamique vers le curseur
      if (lassoMouse != null) {
        canvas.drawLine(lassoPts.last, lassoMouse!, linePaint);
      }
      // Contour fermé (aperçu)
      if (lassoPts.length > 2) {
        canvas.drawLine(
            lassoPts.last,
            lassoPts.first,
            Paint()
              ..color = Colors.orangeAccent.withValues(alpha: 0.3)
              ..strokeWidth = 1
              ..style = PaintingStyle.stroke);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MaskPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialog principal v3
// ─────────────────────────────────────────────────────────────────────────────

class InpaintEditorDialog extends StatefulWidget {
  final Uint8List imageBytes;
  // P2 — persistance : valeurs initiales depuis les prefs
  final String? savedInpaintModel;  // null = auto
  final String? savedGenModel;      // null = auto
  // P2 — persistance : callback pour sauvegarder la sélection
  final void Function(String? inpaintModel, String? genModel)? onModelChanged;

  const InpaintEditorDialog({
    super.key,
    required this.imageBytes,
    this.savedInpaintModel,
    this.savedGenModel,
    this.onModelChanged,
  });

  @override
  State<InpaintEditorDialog> createState() => _InpaintEditorDialogState();
}

class _InpaintEditorDialogState extends State<InpaintEditorDialog> {
  // ── Image de travail + historique ─────────────────────────────────────────
  late Uint8List _currentImage;
  final List<Uint8List> _imageHistory = [];
  ui.Image? _decodedImage;

  // ── Opérations de masque ──────────────────────────────────────────────────
  final List<_MaskOp> _ops = [];
  final List<_MaskOp> _opsRedo = [];

  // ── Outil actif ───────────────────────────────────────────────────────────
  _ToolMode _tool = _ToolMode.brush;

  // ── Brush/Eraser state ────────────────────────────────────────────────────
  _MaskOp? _activeBrushOp;
  double _brushSize = 36.0;

  // ── Rectangle state ───────────────────────────────────────────────────────
  Offset? _rectStart;
  Offset? _rectCurrent;

  // ── Lasso state ───────────────────────────────────────────────────────────
  final List<Offset> _lassoPts = [];
  Offset? _lassoMouse;

  // ── Paramètres ────────────────────────────────────────────────────────────
  double _strength = 0.75;
  final _promptCtrl = TextEditingController();

  // ── État UI ───────────────────────────────────────────────────────────────
  bool _isProcessing = false;
  bool _isMaximized = false;
  // P2 — deux sélecteurs distincts
  List<String> _inpaintModels = [];      // modèles type=inpaint
  List<String> _genModels = [];          // modèles type!=inpaint
  String? _selectedInpaintModel;         // null = auto
  String? _selectedGenModel;             // null = auto
  bool _serverReachable = false;         // distingue "injoignable" de "0 modèle"
  String? _statusMsg;
  bool _statusIsError = false;
  int _modifCount = 0;

  final GlobalKey _canvasKey = GlobalKey();
  final TransformationController _ivCtrl = TransformationController();

  bool get _isErase =>
      _tool == _ToolMode.eraser;

  @override
  void initState() {
    super.initState();
    _currentImage = widget.imageBytes;
    _decodeImage(_currentImage);
    _fetchAvailableModels();
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _ivCtrl.dispose();
    super.dispose();
  }

  // ── P2 — Chargement de la liste des modèles depuis le nouveau endpoint ──────

  Future<void> _fetchAvailableModels() async {
    try {
      final req = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7860/v1/models/image'));
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final list = (jsonDecode(body) as List)
            .cast<Map<String, dynamic>>();
        final inpaint = list
            .where((m) => m['is_inpainting'] == true)
            .map((m) => m['name'] as String)
            .toList();
        final gen = list
            .where((m) => m['is_inpainting'] != true)
            .map((m) => m['name'] as String)
            .toList();
        if (mounted) {
          setState(() {
            _serverReachable = true;
            _inpaintModels = inpaint;
            _genModels = gen;
            // P2 — Restauration des prefs (si le modèle sauvegardé est toujours disponible)
            final savedInpaint = widget.savedInpaintModel;
            final savedGen = widget.savedGenModel;
            _selectedInpaintModel = (savedInpaint != null && inpaint.contains(savedInpaint))
                ? savedInpaint
                : (inpaint.isNotEmpty ? inpaint.first : null);
            _selectedGenModel = (savedGen != null && gen.contains(savedGen))
                ? savedGen
                : (gen.isNotEmpty ? gen.first : null);
          });
        }
      }
    } catch (_) {
      // Serveur injoignable — _serverReachable reste false
      if (mounted) setState(() => _serverReachable = false);
    }
  }

  Future<void> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _decodedImage = frame.image);
  }

  // ── Coordonnées locales (gère le zoom via globalToLocal) ─────────────────

  Offset _local(Offset global) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  // ── Gestion des gestes selon l'outil ─────────────────────────────────────

  void _onPanStart(DragStartDetails d) {
    if (_tool == _ToolMode.pan) return;
    final pt = _local(d.globalPosition);

    switch (_tool) {
      case _ToolMode.brush:
      case _ToolMode.eraser:
        setState(() => _activeBrushOp = _MaskOp.brush(
              [pt], _brushSize,
              erase: _isErase));
      case _ToolMode.rectangle:
        setState(() { _rectStart = pt; _rectCurrent = pt; });
      default:
        break;
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_tool == _ToolMode.pan) return;
    final pt = _local(d.globalPosition);

    switch (_tool) {
      case _ToolMode.brush:
      case _ToolMode.eraser:
        if (_activeBrushOp == null) return;
        setState(() => _activeBrushOp = _MaskOp.brush(
              [..._activeBrushOp!.points, pt], _brushSize,
              erase: _isErase));
      case _ToolMode.rectangle:
        setState(() => _rectCurrent = pt);
      default:
        break;
    }
  }

  void _onPanEnd(DragEndDetails _) {
    if (_tool == _ToolMode.pan) return;

    switch (_tool) {
      case _ToolMode.brush:
      case _ToolMode.eraser:
        if (_activeBrushOp == null) return;
        setState(() {
          _ops.add(_activeBrushOp!);
          _opsRedo.clear();
          _activeBrushOp = null;
          _statusMsg = null;
        });
      case _ToolMode.rectangle:
        if (_rectStart == null || _rectCurrent == null) return;
        final r = Rect.fromPoints(_rectStart!, _rectCurrent!);
        if (r.width > 2 && r.height > 2) {
          setState(() {
            _ops.add(_MaskOp.rectangle(r, erase: _isErase));
            _opsRedo.clear();
          });
        }
        setState(() { _rectStart = null; _rectCurrent = null; });
      default:
        break;
    }
  }

  // ── Lasso : clic pour ajouter un point ────────────────────────────────────

  void _onTapDown(TapDownDetails d) {
    if (_tool != _ToolMode.lasso) return;
    final pt = _local(d.globalPosition);

    // Si proche du premier point → fermer le polygone
    if (_lassoPts.length >= 3) {
      final dist = (pt - _lassoPts.first).distance;
      if (dist < 16) {
        _closeLasso();
        return;
      }
    }
    setState(() => _lassoPts.add(pt));
  }

  void _onMouseMove(PointerHoverEvent e) {
    if (_tool != _ToolMode.lasso || _lassoPts.isEmpty) return;
    setState(() => _lassoMouse = _local(e.position));
  }

  void _closeLasso({bool erase = false}) {
    if (_lassoPts.length < 3) return;
    setState(() {
      _ops.add(_MaskOp.polygon(List.of(_lassoPts), erase: erase || _isErase));
      _opsRedo.clear();
      _lassoPts.clear();
      _lassoMouse = null;
      _statusMsg = null;
    });
  }

  void _cancelLasso() => setState(() { _lassoPts.clear(); _lassoMouse = null; });

  // ── Undo/Redo/Clear ───────────────────────────────────────────────────────

  void _undo() {
    if (_ops.isEmpty) return;
    setState(() => _opsRedo.add(_ops.removeLast()));
  }

  void _redo() {
    if (_opsRedo.isEmpty) return;
    setState(() => _ops.add(_opsRedo.removeLast()));
  }

  void _clearMask() => setState(() {
        _ops.clear();
        _opsRedo.clear();
        _activeBrushOp = null;
        _lassoPts.clear();
        _lassoMouse = null;
        _rectStart = null;
        _rectCurrent = null;
      });

  bool get _hasMask => _ops.isNotEmpty || _activeBrushOp != null;

  // ── Undo image-level ──────────────────────────────────────────────────────

  void _undoImage() {
    if (_imageHistory.isEmpty) return;
    final prev = _imageHistory.removeLast();
    _currentImage = prev;
    _clearMask();
    _modifCount--;
    setState(() {
      _statusMsg = '↩ Revenu à la version précédente.';
      _statusIsError = false;
    });
    _decodeImage(prev);
  }

  // ── P3 — Chargement depuis le disque (dialog natif, API file_picker v12) ──

  Future<void> _loadFromDisk() async {
    // FilePicker v12 : méthode statique directe, retourne PlatformFile? directement
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'tiff', 'gif'],
      dialogTitle: 'Charger une image',
      lockParentWindow: true,
    );
    if (file == null) return;

    try {
      final path = file.path;
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      _imageHistory.clear();
      _currentImage = bytes;
      _clearMask();
      _modifCount = 0;
      setState(() {
        _statusMsg = '📂 Image chargée : ${file.name}';
        _statusIsError = false;
      });
      await _decodeImage(bytes);
    } catch (e) {
      setState(() {
        _statusMsg = 'Erreur chargement : $e';
        _statusIsError = true;
      });
    }
  }

  // ── Export masque PNG (résolution native) ─────────────────────────────────

  Future<Uint8List> _exportMask() async {
    final img = _decodedImage!;
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final dw = box?.size.width ?? iw;
    final dh = box?.size.height ?? ih;
    final sx = iw / dw;
    final sy = ih / dh;

    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);

    // Fond noir (zones conservées)
    canvas.drawRect(Rect.fromLTWH(0, 0, iw, ih), Paint()..color = Colors.black);

    // Échelle des opérations display → native
    canvas.save();
    canvas.scale(sx, sy);

    for (final op in _ops) {
      _MaskPainter._paintOp(canvas, op, forExport: true);
    }

    canvas.restore();

    final pic = rec.endRecording();
    final mi = await pic.toImage(img.width, img.height);
    final bd = await mi.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  }

  // ── Inpainting ────────────────────────────────────────────────────────────

  Future<void> _runInpaint() async {
    if (!_hasMask || _decodedImage == null) return;
    setState(() { _isProcessing = true; _statusMsg = null; });

    try {
      final maskBytes = await _exportMask();
      final bodyStr = jsonEncode({
        'image': base64Encode(_currentImage),
        'mask': base64Encode(maskBytes),
        'prompt': _promptCtrl.text.trim().isEmpty
            ? 'high quality photo, seamless'
            : _promptCtrl.text.trim(),
        'strength': _strength,
        'steps': 20,
        // P2 — transmet le modèle inpainting choisi explicitement
        if (_selectedInpaintModel != null && _selectedInpaintModel!.isNotEmpty)
          'model': _selectedInpaintModel!,
      });

      final req = await HttpClient()
          .postUrl(Uri.parse('http://127.0.0.1:7860/inpaint'));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      final bodyBytes = utf8.encode(bodyStr);
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode == 200) {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final resultBytes =
            base64Decode((json['images'] as List).first as String);

        _imageHistory.add(_currentImage);
        _currentImage = resultBytes;
        await _decodeImage(resultBytes);
        _clearMask();
        _modifCount++;

        setState(() {
          _statusMsg =
              '✅ Modification $_modifCount appliquée — peignez pour continuer.';
          _statusIsError = false;
        });
      } else {
        setState(() {
          _statusMsg = 'Erreur serveur (${res.statusCode}) : $body';
          _statusIsError = true;
        });
      }
    } catch (e) {
      setState(() { _statusMsg = 'Erreur : $e'; _statusIsError = true; });
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ── P4 — Sauvegarde (Save As natif, API file_picker v12) ─────────────────

  Future<void> _saveImage() async {
    try {
      final ts = DateTime.now();
      final defaultName =
          'inpaint_${ts.hour}h${ts.minute.toString().padLeft(2, '0')}.png';

      // FilePicker v12 : saveFile() est statique, bytes requis, le plugin écrit lui-même
      final savedPath = await FilePicker.saveFile(
        dialogTitle: "Enregistrer l'image",
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg'],
        bytes: _currentImage,
        lockParentWindow: true,
      );

      if (savedPath == null) return; // annulé par l'utilisateur
      setState(() {
        _statusMsg = '💾 Enregistré : $savedPath';
        _statusIsError = false;
      });
    } catch (e) {
      setState(() { _statusMsg = 'Erreur : $e'; _statusIsError = true; });
    }
  }


  // ── Reset zoom ────────────────────────────────────────────────────────────

  void _resetZoom() {
    _ivCtrl.value = Matrix4.identity();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hint = isDark ? Colors.white54 : Colors.black54;
    final bgColor = isDark ? const Color(0xFF1A1D2E) : Colors.white;
    final screen = MediaQuery.of(context).size;

    final Rect? rectPreview = (_rectStart != null && _rectCurrent != null)
        ? Rect.fromPoints(_rectStart!, _rectCurrent!)
        : null;

    // Hauteur du canvas : maximisée = écran - contrôles (~390px), normale = 340
    final double canvasH =
        _isMaximized ? (screen.height - 390).clamp(200, 2000) : 340.0;

    return Dialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_isMaximized ? 0 : 18)),
      insetPadding: _isMaximized
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: _isMaximized ? double.infinity : 800),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Titre + actions rapides ────────────────────────────────
              Row(children: [
                const Icon(Icons.brush, color: Colors.orangeAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Éditeur d\'inpainting',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    if (_modifCount > 0)
                      Text(
                          '$_modifCount modification${_modifCount > 1 ? "s" : ""} appliquée${_modifCount > 1 ? "s" : ""}',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.orangeAccent)),
                  ],
                )),
                // Charger depuis disque
                TextButton.icon(
                  onPressed: _isProcessing ? null : _loadFromDisk,
                  icon: const Icon(Icons.folder_open, size: 15),
                  label: const Text('Charger', style: TextStyle(fontSize: 12)),
                ),
                // Undo image-level
                IconButton(
                  onPressed: _imageHistory.isNotEmpty && !_isProcessing
                      ? _undoImage : null,
                  icon: const Icon(Icons.history, size: 18),
                  tooltip: 'Version précédente',
                ),
                // Maximiser / Restaurer
                IconButton(
                  onPressed: () => setState(() => _isMaximized = !_isMaximized),
                  icon: Icon(
                    _isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 20),
                  tooltip: _isMaximized ? 'Réduire' : 'Maximiser',
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context, null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
              const SizedBox(height: 8),

              // ── Barre d'outils ─────────────────────────────────────────
              _buildToolbar(hint),
              const SizedBox(height: 8),

              // ── Canvas ────────────────────────────────────────────────
              _buildCanvas(rectPreview, canvasH),
              const SizedBox(height: 6),

              // ── Contrôles brush/zoom ───────────────────────────────────
              _buildBrushControls(hint),

              // ── Slider force ───────────────────────────────────────────
              _buildStrengthSlider(hint),

              // ── P2 — Sélecteur modèle inpainting ─────────────────────
              const SizedBox(height: 6),
              if (_serverReachable) ...[
                // Sélecteur inpainting
                if (_inpaintModels.isNotEmpty) ...[
                  Row(children: [
                    const Icon(Icons.memory, size: 13, color: Colors.purpleAccent),
                    const SizedBox(width: 5),
                    const Text('Inpainting :', style: TextStyle(fontSize: 11)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        isDense: true,
                        value: _selectedInpaintModel,
                        style: const TextStyle(fontSize: 11),
                        underline: const SizedBox.shrink(),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('Auto', style: TextStyle(fontStyle: FontStyle.italic)),
                          ),
                          ..._inpaintModels.map((m) {
                            final short = m.replaceAll(RegExp(r'\.(safetensors|gguf|ckpt)$'), '');
                            final label = short.length > 40 ? '${short.substring(0, 37)}…' : short;
                            return DropdownMenuItem(
                              value: m,
                              child: Tooltip(message: m, child: Text(label)),
                            );
                          }),
                        ],
                        onChanged: _isProcessing
                            ? null
                            : (v) {
                                setState(() => _selectedInpaintModel = v);
                                // P2 — persistance : notifie le parent pour sauvegarder
                                widget.onModelChanged?.call(v, _selectedGenModel);
                              },
                      ),
                    ),
                  ]),
                ] else ...[
                  Row(children: [
                    const Icon(Icons.warning_amber, size: 13, color: Colors.orange),
                    const SizedBox(width: 5),
                    const Text('Aucun modèle inpainting détecté',
                        style: TextStyle(fontSize: 10, color: Colors.orange)),
                  ]),
                ],
              ] else ...[
                Row(children: [
                  const Icon(Icons.error_outline, size: 13, color: Colors.redAccent),
                  const SizedBox(width: 5),
                  const Text('⚠️ Serveur image injoignable (127.0.0.1:7860)',
                      style: TextStyle(fontSize: 10, color: Colors.redAccent)),
                ]),
              ],

              const SizedBox(height: 6),

              // ── Prompt ────────────────────────────────────────────────
              TextField(
                controller: _promptCtrl,
                maxLines: 1,
                decoration: InputDecoration(
                  hintText: 'Décrire ce qui remplace la zone masquée…',
                  labelText: 'Prompt (vide = effacer)',
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                ),
              ),

              // ── Lasso : boutons fermer/annuler ─────────────────────────
              if (_lassoPts.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.info_outline,
                      size: 14, color: Colors.orangeAccent),
                  const SizedBox(width: 6),
                  Text(
                      '${_lassoPts.length} point${_lassoPts.length > 1 ? "s" : ""} — cliquez sur le premier point ou :',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.orangeAccent)),
                  const Spacer(),
                  TextButton(
                      onPressed: _cancelLasso,
                      child: const Text('Annuler', style: TextStyle(fontSize: 11))),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _lassoPts.length >= 3 ? _closeLasso : null,
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.orangeAccent.shade700,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4)),
                    child: const Text('⬡ Fermer', style: TextStyle(fontSize: 11)),
                  ),
                ]),
              ],

              // ── Statut ────────────────────────────────────────────────
              if (_statusMsg != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: (_statusIsError ? Colors.red : Colors.green)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                        color: (_statusIsError
                                ? Colors.redAccent
                                : Colors.greenAccent)
                            .withValues(alpha: 0.35)),
                  ),
                  child: Text(_statusMsg!,
                      style: TextStyle(
                          fontSize: 11,
                          color: _statusIsError
                              ? Colors.redAccent
                              : Colors.greenAccent)),
                ),
              ],

              const SizedBox(height: 10),

              // ── Boutons d'action ───────────────────────────────────────
              Row(children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.save_alt,
                      size: 14, color: Colors.cyanAccent),
                  label: const Text('💾 Enregistrer',
                      style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.cyanAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4)),
                  onPressed:
                      (_modifCount > 0 && !_isProcessing) ? _saveImage : null,
                ),
                const Spacer(),
                TextButton(
                  onPressed:
                      _isProcessing ? null : () => Navigator.pop(context, null),
                  child: const Text('Fermer', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed: (_hasMask && !_isProcessing) ? _runInpaint : null,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 13, height: 13,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.auto_fix_high, size: 14),
                  label: Text(
                      _isProcessing ? '⏳ Traitement…' : '✨ Inpeindre',
                      style: const TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.orangeAccent.shade700,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6)),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed: (_modifCount > 0 && !_isProcessing)
                      ? () => Navigator.pop(context, _currentImage) : null,
                  icon: const Icon(Icons.send, size: 14),
                  label: const Text('Envoyer au chat',
                      style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6)),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  // ── Barre d'outils ────────────────────────────────────────────────────────

  Widget _buildToolbar(Color hint) {
    Widget toolBtn(_ToolMode mode, IconData icon, String tooltip) {
      final active = _tool == mode;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => setState(() {
            _tool = mode;
            // Annule lasso si on change d'outil
            if (mode != _ToolMode.lasso) _cancelLasso();
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? Colors.orangeAccent.withValues(alpha: 0.2)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: active
                    ? Colors.orangeAccent
                    : Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon,
                  size: 15,
                  color: active ? Colors.orangeAccent : hint),
              const SizedBox(width: 4),
              Text(tooltip.split(' ').first,
                  style: TextStyle(
                      fontSize: 11,
                      color: active ? Colors.orangeAccent : hint,
                      fontWeight:
                          active ? FontWeight.bold : FontWeight.normal)),
            ]),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        toolBtn(_ToolMode.brush, Icons.brush, 'Pinceau'),
        const SizedBox(width: 4),
        toolBtn(_ToolMode.eraser, Icons.auto_fix_off, 'Gomme'),
        const SizedBox(width: 4),
        toolBtn(_ToolMode.rectangle, Icons.crop_square, 'Rectangle'),
        const SizedBox(width: 4),
        toolBtn(_ToolMode.lasso, Icons.pentagon_outlined, 'Polygone'),
        const SizedBox(width: 4),
        toolBtn(_ToolMode.pan, Icons.pan_tool, 'Navigation'),
        const SizedBox(width: 12),
        // Undo/Redo/Clear masque
        IconButton(
            onPressed: _ops.isNotEmpty ? _undo : null,
            icon: const Icon(Icons.undo, size: 17),
            tooltip: 'Annuler', padding: EdgeInsets.zero,
            constraints: const BoxConstraints()),
        const SizedBox(width: 2),
        IconButton(
            onPressed: _opsRedo.isNotEmpty ? _redo : null,
            icon: const Icon(Icons.redo, size: 17),
            tooltip: 'Rétablir', padding: EdgeInsets.zero,
            constraints: const BoxConstraints()),
        const SizedBox(width: 2),
        IconButton(
            onPressed: _hasMask ? _clearMask : null,
            icon: const Icon(Icons.delete_sweep, size: 17),
            tooltip: 'Effacer masque', padding: EdgeInsets.zero,
            constraints: const BoxConstraints()),
        const Spacer(),
        // Zoom reset
        TextButton.icon(
          onPressed: _resetZoom,
          icon: const Icon(Icons.zoom_out_map, size: 14),
          label: const Text('100%', style: TextStyle(fontSize: 11)),
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2)),
        ),
      ]),
    );
  }

  // ── Canvas avec zoom ──────────────────────────────────────────────────────

  Widget _buildCanvas(Rect? rectPreview, [double canvasHeight = 340]) {
    final isPanMode = _tool == _ToolMode.pan;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: canvasHeight,
        color: Colors.black12,
        child: InteractiveViewer(
          transformationController: _ivCtrl,
          panEnabled: isPanMode,
          scaleEnabled: true,
          minScale: 0.5,
          maxScale: 5.0,
          child: MouseRegion(
            onHover: _onMouseMove,
            cursor: _toolCursor(),
            child: GestureDetector(
              onPanStart: isPanMode ? null : _onPanStart,
              onPanUpdate: isPanMode ? null : _onPanUpdate,
              onPanEnd: isPanMode ? null : _onPanEnd,
              onTapDown: _tool == _ToolMode.lasso ? _onTapDown : null,
              child: Stack(children: [
                // Image de travail
                Image.memory(
                  _currentImage,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
                // Calque masque
                Positioned.fill(
                  child: SizedBox(
                    key: _canvasKey,
                    child: CustomPaint(
                      painter: _MaskPainter(
                        ops: _ops,
                        activeOp: _activeBrushOp,
                        lassoPts: _lassoPts,
                        lassoMouse: _lassoMouse,
                        rectPreview: rectPreview,
                        rectErase: _isErase,
                      ),
                    ),
                  ),
                ),
                // Overlay processing
                if (_isProcessing)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Colors.orangeAccent),
                          SizedBox(height: 12),
                          Text('Inpainting en cours…',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  SystemMouseCursor _toolCursor() {
    switch (_tool) {
      case _ToolMode.pan: return SystemMouseCursors.grab;
      case _ToolMode.eraser: return SystemMouseCursors.precise;
      case _ToolMode.rectangle: return SystemMouseCursors.cell;
      case _ToolMode.lasso: return SystemMouseCursors.click;
      default: return SystemMouseCursors.precise;
    }
  }

  // ── Contrôles pinceau ─────────────────────────────────────────────────────

  Widget _buildBrushControls(Color hint) {
    final showBrush =
        _tool == _ToolMode.brush || _tool == _ToolMode.eraser;
    if (!showBrush) return const SizedBox(height: 4);
    return Row(children: [
      const Icon(Icons.radio_button_unchecked, size: 10, color: Colors.white38),
      Expanded(child: Slider(
        value: _brushSize, min: 4, max: 100,
        label: '${_brushSize.round()}px',
        onChanged: (v) => setState(() => _brushSize = v),
      )),
      const Icon(Icons.circle, size: 26, color: Colors.white38),
    ]);
  }

  // ── Slider force ──────────────────────────────────────────────────────────

  Widget _buildStrengthSlider(Color hint) {
    return Row(children: [
      Text('Force', style: TextStyle(fontSize: 11, color: hint)),
      Expanded(child: Slider(
        value: _strength, min: 0.3, max: 1.0, divisions: 14,
        label: '${(_strength * 100).round()}%',
        onChanged: (v) => setState(() => _strength = v),
      )),
      SizedBox(width: 40,
          child: Text('${(_strength * 100).round()}%',
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold))),
    ]);
  }
}
