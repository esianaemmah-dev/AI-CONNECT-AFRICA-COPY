import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../ai_core/inference/runtime_config.dart';
import '../../ai_core/providers/ai_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/app_locale.dart';
import '../../services/ai_coder_service.dart';
import '../../shared/coding/code_autocorrect.dart' show CodeAutocorrectKind;
import '../../shared/coding/code_instruction_edit.dart';
import '../../shared/coding/html_images.dart'
    show PickedImage, applyPickedImages, maskEmbeddedImages;
import '../../shared/coding/interactive_html.dart'
    show escapeHtml, extractPageTitle, hasVisibleContent;
import 'interactive_kit.dart';
import '../../shared/widgets/code_instruction_bar.dart';
import '../../shared/widgets/html_preview.dart';
import '../../services/projects/project_providers.dart';
import '../projects/project_actions.dart';
import '../projects/project_files_sheet.dart';
import '../projects/scaffold/project_scaffold.dart';
import '../projects/widgets/image_instruction_runner.dart';
import '../projects/widgets/project_tools_bar.dart';
import '../projects/widgets/project_saved_notice.dart';
import '../create/dev_l10n.dart';
import '../settings/coder_package_prompt.dart';
import 'app_build_coder.dart';
import 'app_type_catalog.dart';
import 'app_type_classifier.dart';
import 'app_type_picker.dart';
import '../../shared/widgets/studio_page.dart';

class _QField {
  const _QField(this.key, this.question, this.hint);
  final String key, question, hint;
}

/// Longest description passed into the coder brief — leaves room in
/// [kCoderMaxPromptChars] for the system prompt and the rest of the brief.
const _kMaxDescriptionChars = 800;

const _askFields = [
  _QField('app_name', "What should we call your app?", 'e.g. StudySpark'),
  _QField(
    'purpose',
    'In one sentence, who is it for and what does it help with?',
    'e.g. Helps students save notes before exams',
  ),
];

const _colorThemes = {
  '1': {'name': 'Ocean Blue', 'primary': '#2563eb'},
  '2': {'name': 'Forest Green', 'primary': '#059669'},
  '3': {'name': 'Royal Purple', 'primary': '#7c3aed'},
  '4': {'name': 'Sunset Orange', 'primary': '#ea580c'},
  '5': {'name': 'Rose Pink', 'primary': '#e11d48'},
};

class AppChatBuilderScreen extends ConsumerStatefulWidget {
  const AppChatBuilderScreen({super.key});

  @override
  ConsumerState<AppChatBuilderScreen> createState() =>
      _AppChatBuilderScreenState();
}

class _AppChatBuilderScreenState extends ConsumerState<AppChatBuilderScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _codeController = TextEditingController();
  final _studioKey = GlobalKey<LiveHtmlStudioState>();

  /// Code as it stood before the last AI change, so it can be reverted.
  String? _undoSnapshot;
  final List<_ChatMsg> _messages = [];
  final Map<String, String> _answers = {};
  final List<String> _selectedFeatures = [];

  AppTypeEntry? _appType;
  int _fieldIndex = -1;

  /// Waiting for the learner to describe an app (or pick one from the list).
  bool _choosingType = true;
  bool _choosingColor = false;
  bool _choosingFeatures = false;
  String _colorKey = '1';
  bool _building = false;
  bool _showStudio = false;
  String _buildNote = '';

  /// The coder is writing a custom page while the learner already has the
  /// ready-made design on screen (see [_upgradeWithCoder]).
  bool _upgrading = false;

  /// Bumped by every build and wizard reset, so a custom page that arrives
  /// late never lands on a newer app.
  int _buildGen = 0;
  bool _autocorrectBusy = false;

  /// English form of the learner's description, when this build came from
  /// free text. Empty on the guided (pick-from-list) path.
  String _description = '';

  /// Page title of the last free-text build, fixed at build time so later
  /// edits don't rename the project folder on every save.
  String? _builtTitle;

  /// Pictures attached before Build, placed on the page once it exists.
  List<PickedImage> _pendingImages = const [];

  /// This build's folder under Projects › Applications once saved; later
  /// saves rewrite the same folder instead of making a new one.
  String? _projectId;
  String? _savedLabel;
  bool _saving = false;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startIntro());
  }

  Future<void> _startIntro() async {
    await _sayBot(
      "Hi! Tell me about the app you want to build, in your own words. 📱\n\n"
      "Say who it's for and what it should do — for example: "
      "\"an app for my class to track who paid school fees\".\n\n"
      "I'll write the app and its backend for you. You can add pictures "
      "with the 🖼 button, or tap ☰ to pick from a list instead.",
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sayBot(String english) async {
    final shown = await localizeDevBot(ref, english);
    if (!mounted) return;
    setState(() => _messages.add(_ChatMsg(shown, true)));
    _scrollDown();
  }

  void _addUser(String text) {
    setState(() => _messages.add(_ChatMsg(text, false)));
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 100,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _onSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _building) return;
    _controller.clear();
    _addUser(text);

    final english = await localizeDevStudent(ref, text);
    if (!mounted) return;

    if (_choosingType) {
      await _handleDescription(english);
    } else if (_choosingColor) {
      await _handleColorChoice(english);
    } else if (_fieldIndex >= 0 && _fieldIndex < _askFields.length) {
      await _handleFieldAnswer(text);
    } else if (_choosingFeatures) {
      await _handleFeatureChoice(english);
    }
  }

  /// Clears what a previous build recorded, so a new description or list
  /// pick starts from nothing.
  void _resetWizard() {
    _answers.clear();
    _selectedFeatures.clear();
    _fieldIndex = -1;
    _colorKey = '1';
    _choosingColor = false;
    _choosingFeatures = false;
    _description = '';
    _builtTitle = null;
    _buildGen++;
    _upgrading = false;
  }

  /// Free-text entry: the description is the whole spec. It is classified
  /// locally (no model call) only to choose which backend and fallback
  /// template the build uses; the page itself is written by the coder model.
  Future<void> _handleDescription(String english) async {
    final text = english.trim();
    if (text.split(RegExp(r'\s+')).length < 3) {
      await _sayBot(
        "Tell me a little more — who is the app for, and what should it do? "
        "Or tap ☰ to pick from a list.",
      );
      return;
    }
    _resetWizard();
    final type = classifyAppType(text);
    _appType = type;
    _description = text.length > _kMaxDescriptionChars
        ? text.substring(0, _kMaxDescriptionChars)
        : text;
    _colorKey = _colorKeyMentionedIn(text) ?? '1';
    _choosingType = false;
    await _sayBot(
      type == kGenericAppType
          ? "Got it! ✍️ Writing your app now…"
          : "Got it! ✍️ Writing your app now — it'll store its data like a "
                "${type.name}.",
    );
    await _buildApp();
  }

  /// A colour the learner named in their description ("a green app…").
  String? _colorKeyMentionedIn(String text) {
    final lower = text.toLowerCase();
    for (final e in _colorThemes.entries) {
      final word = e.value['name']!.toLowerCase().split(' ').last;
      if (RegExp('\\b$word\\b').hasMatch(lower)) return e.key;
    }
    return null;
  }

  /// Guided entry: the list picker, then the original colour → name/purpose
  /// → features questions and the template build, with no model call.
  Future<void> _pickFromList() async {
    if (_building) return;
    final chosen = await showAppTypePicker(context);
    if (chosen == null || !mounted) return;
    _resetWizard();
    _addUser(chosen.name);
    _appType = chosen;
    _choosingType = false;
    _choosingColor = true;
    await _sayBot("Great — ${chosen.name}! 🎨 Pick a color theme:");
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _sayBot(
      "① Ocean Blue\n② Forest Green\n③ Royal Purple\n"
      "④ Sunset Orange\n⑤ Rose Pink\n\nType a number!",
    );
  }

  Future<void> _attachPictures() async {
    final picked = await pickPictures(context);
    if (picked.isEmpty || !mounted) return;
    setState(() => _pendingImages = [..._pendingImages, ...picked]);
  }

  Future<void> _handleColorChoice(String text) async {
    final lower = text.trim().toLowerCase();
    String key = '1';
    for (final e in _colorThemes.entries) {
      if (lower == e.key ||
          lower.contains(e.value['name']!.toLowerCase().split(' ').first)) {
        key = e.key;
        break;
      }
    }
    _colorKey = key;
    _choosingColor = false;
    _fieldIndex = 0;
    await _sayBot(
      "${_colorThemes[key]!['name']} selected. ✨ Two quick details:",
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _askCurrentField();
  }

  Future<void> _askCurrentField() async {
    if (_fieldIndex < 0 || _fieldIndex >= _askFields.length) return;
    final field = _askFields[_fieldIndex];
    await _sayBot("${field.question}\n\n💡 ${field.hint}");
  }

  Future<void> _handleFieldAnswer(String text) async {
    final field = _askFields[_fieldIndex];
    _answers[field.key] = text.trim();
    _fieldIndex++;
    if (_fieldIndex >= _askFields.length) {
      _choosingFeatures = true;
      final opts = _appType!.featureOptions;
      final listed = opts
          .asMap()
          .entries
          .map((e) => '${e.key + 1}️⃣ ${e.value}')
          .join('\n');
      await _sayBot(
        "Which features should this app include?\n\n$listed\n\n"
        "Type numbers like 1,2,4 — or type all",
      );
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _askCurrentField();
    }
  }

  Future<void> _handleFeatureChoice(String text) async {
    final opts = _appType!.featureOptions;
    final lower = text.toLowerCase().trim();
    _selectedFeatures.clear();
    if (lower == 'all' || lower.contains('all')) {
      _selectedFeatures.addAll(opts);
    } else {
      for (var i = 0; i < opts.length; i++) {
        final n = '${i + 1}';
        if (RegExp('\\b$n\\b').hasMatch(lower) ||
            lower.contains(opts[i].toLowerCase())) {
          _selectedFeatures.add(opts[i]);
        }
      }
    }
    if (_selectedFeatures.isEmpty) {
      _selectedFeatures.add(opts.first);
    }
    _choosingFeatures = false;
    final recorded = tr(
      context,
      'Features recorded: ${_selectedFeatures.join(', ')}. ✅ '
      'Building your app…',
    );
    setState(() => _messages.add(_ChatMsg(recorded, true)));
    _scrollDown();
    await _buildApp();
  }

  AppBuildIntent _currentIntent() {
    final theme = _colorThemes[_colorKey]!;
    return AppBuildIntent(
      appTypeId: _appType!.id,
      appTypeName: _appType!.name,
      themeId: _colorKey,
      themeName: theme['name']!,
      themePrimary: theme['primary']!,
      answers: Map<String, String>.from(_answers),
      features: List<String>.from(_selectedFeatures),
      description: _description,
    );
  }

  void _applyCodeEdits() {
    setState(() {});
    if (_projectId != null) _saveToProjects(quiet: true);
  }

  // ── Project folder ───────────────────────────────────────────────────────

  String get _appTitle {
    final name = _answers['app_name']?.trim();
    if (name != null && name.isNotEmpty) return name;
    final built = _builtTitle;
    if (built != null && built.isNotEmpty) return built;
    return _appType?.name ?? 'My app';
  }

  /// Writes the app as a full project (frontend + FastAPI/SQLite backend +
  /// docs) under Projects › Applications — the first time as a new folder,
  /// then into the same folder. [quiet] skips the snackbar for auto-saves.

  // Saves run one at a time. A save asked for while one is running is not
  // dropped: it marks [_saveAgain] and the running loop saves once more with
  // the latest code, so a quick style change right after Build still lands.
  Future<ProjectFolder?>? _saveInFlight;
  bool _saveAgain = false;
  bool _saveLoud = false;

  /// Saves the project (or queues one more save). The returned future
  /// completes after the newest code is on disk.
  Future<ProjectFolder?> _saveToProjects({bool quiet = false}) {
    _saveAgain = true;
    if (!quiet) _saveLoud = true;
    return _saveInFlight ??= _drainSaves().whenComplete(
      () => _saveInFlight = null,
    );
  }

  Future<ProjectFolder?> _drainSaves() async {
    ProjectFolder? last;
    if (mounted) setState(() => _saving = true);
    try {
      while (_saveAgain && mounted) {
        _saveAgain = false;
        final loud = _saveLoud;
        _saveLoud = false;
        last = await _saveOnce(quiet: !loud) ?? last;
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    return last;
  }

  Future<ProjectFolder?> _saveOnce({required bool quiet}) async {
    if (_appType == null) return null;
    final html = _codeController.text;
    if (html.trim().isEmpty) return null;
    try {
      final intent = _currentIntent();
      final images = <String, Uint8List>{};
      final files = buildAppProject(
        title: _appTitle,
        html: html,
        appTypeId: intent.appTypeId,
        appTypeName: intent.appTypeName,
        themeColor: intent.themePrimary,
        features: intent.features,
        images: images,
      );
      final saved = await saveCreation(
        ref,
        kind: ProjectKind.application,
        title: _appTitle,
        files: files,
        binaryFiles: images,
        projectId: _projectId,
        source: 'app_builder',
        template: intent.appTypeId,
        templateName: intent.appTypeName,
        features: intent.features,
        answers: {
          ...intent.answers,
          if (intent.description.isNotEmpty) 'description': intent.description,
        },
      );
      if (!mounted) return saved?.folder;
      if (saved == null) {
        if (!quiet) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(context, 'Create a learner profile to save projects.'),
              ),
            ),
          );
        }
        return null;
      }
      setState(() {
        _projectId = saved.folder.manifest.id;
        _savedLabel = saved.breadcrumb;
      });
      if (!quiet) {
        showProjectSavedNotice(
          context,
          name: saved.breadcrumb,
          onOpen: () => context.push('/projects'),
        );
      }
      return saved.folder;
    } catch (e) {
      debugPrint('app project save failed: $e');
      if (mounted && !quiet) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(context, "Couldn't save your project. Try again."),
            ),
          ),
        );
      }
      return null;
    }
  }

  /// Swaps the screen for [html], keeps [undo] for the Undo snackbar,
  /// repaints and re-saves the project folder.
  void _replaceCode(String html, {required String undo}) {
    _undoSnapshot = undo;
    _codeController.text = html;
    _studioKey.currentState?.applyNow();
    if (_projectId != null) _saveToProjects(quiet: true);
  }

  Future<void> _addPictures() async {
    final before = _codeController.text;
    final updated = await showAddPicturesFlow(context, before);
    if (updated == null || !mounted) return;
    _replaceCode(updated, undo: before);
    showInstructionAppliedSnack(context, onUndo: _undoLastInstruction);
  }

  Future<void> _openStyle() async {
    final before = _codeController.text;
    final updated = await showStyleSheet(context, before);
    if (updated == null || !mounted) return;
    _replaceCode(updated, undo: before);
    showInstructionAppliedSnack(context, onUndo: _undoLastInstruction);
  }

  /// Shows the generated backend files (models, routes, tests) read-only.
  Future<void> _viewBackend() async {
    final folder = await _saveToProjects(quiet: true);
    if (folder == null || !mounted) return;
    await showProjectFilesSheet(context, folder, initialPrefix: 'backend/');
  }

  Future<void> _exportProject() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final folder = await _saveToProjects(quiet: true);
      if (folder == null || !mounted) return;
      await exportProjectZip(context, ref, folder);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _undoLastInstruction() async {
    final previous = _undoSnapshot;
    if (previous == null) return;
    _undoSnapshot = null;
    _codeController.text = previous;
    _studioKey.currentState?.applyNow();
    if (_projectId != null) await _saveToProjects(quiet: true);
  }

  /// Runs a plain-English restyle request ("center the text", "make it
  /// green") through the coder model and repaints the preview on success.
  Future<void> _applyInstruction(String instruction) async {
    if (_autocorrectBusy) return;
    final before = _codeController.text;
    if (before.trim().isEmpty) return;
    // Colour / font / size requests apply instantly, with no model call.
    final styled = tryQuickStyleInstruction(before, instruction);
    if (styled != null) {
      _replaceCode(styled, undo: before);
      showInstructionAppliedSnack(context, onUndo: _undoLastInstruction);
      return;
    }
    final coderOk = await promptAndFetchCoderPackage(context, ref);
    if (!coderOk || !mounted) return;
    setState(() => _autocorrectBusy = true);
    try {
      final engine = await ref.read(programmingEngineProvider.future);
      // Pictures go to the model as short placeholders, not megabytes of
      // base64 that would crowd out the page itself.
      final masked = maskEmbeddedImages(before);
      final edited = await applyCodeInstruction(
        source: masked.text,
        instruction: instruction,
        kind: CodeAutocorrectKind.html,
        engine: engine,
      );
      final fixed = edited == null ? null : masked.restore(edited);
      if (!mounted) return;
      if (fixed == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                "Couldn't apply that — try describing it a different way.",
              ),
            ),
          ),
        );
        return;
      }
      _replaceCode(fixed, undo: before);
      if (!mounted) return;
      showInstructionAppliedSnack(context, onUndo: _undoLastInstruction);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, 'Something went wrong. Please try again.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _autocorrectBusy = false);
    }
  }

  /// A picture from the Tell-AI bar plus what to do with it ("make it the
  /// logo", "use its colours", "put it in the about section").
  Future<void> _applyImageInstruction(
    String instruction,
    List<PickedImage> images,
  ) async {
    if (_autocorrectBusy) return;
    final before = _codeController.text;
    if (before.trim().isEmpty) return;
    setState(() => _autocorrectBusy = true);
    try {
      final done = await runImageInstruction(
        context: context,
        ref: ref,
        html: before,
        instruction: instruction,
        images: images,
      );
      if (!mounted) return;
      if (done == null) {
        showInstructionNoticeSnack(
          context,
          tr(
            context,
            "That didn't change the app — try saying where the picture should go.",
          ),
        );
        return;
      }
      if (done.html == before) {
        showInstructionNoticeSnack(context, done.message);
        return;
      }
      _replaceCode(done.html, undo: before);
      showInstructionAppliedSnack(
        context,
        onUndo: _undoLastInstruction,
        message: done.message,
      );
    } finally {
      if (mounted) setState(() => _autocorrectBusy = false);
    }
  }

  /// Maps the student's app name, purpose, theme, and chosen features onto
  /// the screen template for this app type. Every value is HTML-escaped; the
  /// feature list is markup this method builds itself, so it goes in raw.
  Future<String> _assembleAppHtml(AppBuildIntent intent) async {
    final type = _appType!;
    var html = await rootBundle.loadString(
      'assets/templates/apps/${type.templateId}.html',
    );

    final appName = intent.appName.trim().isEmpty ? 'My App' : intent.appName;
    final description = intent.description.trim();
    final purpose = intent.purpose.trim().isNotEmpty
        ? intent.purpose
        : description.isNotEmpty
        ? (description.length > 140
              ? '${description.substring(0, 140)}…'
              : description)
        : type.name;
    final tokens = <String, String>{
      'app_name': appName,
      'type_name': type.name,
      'purpose': purpose,
      'primary': intent.themePrimary,
      'initial': appName.trim().substring(0, 1).toUpperCase(),
      'stat1': '3',
      'stat2': '12',
      'stat3': '48',
      for (final entry in type.autoFields.entries)
        entry.key: pickAutoField(entry.value),
    };

    for (final entry in tokens.entries) {
      html = html.replaceAll('{{${entry.key}}}', escapeHtml(entry.value));
    }

    final features = intent.features.isEmpty
        ? ['Home screen']
        : intent.features;
    final list = StringBuffer('<ul>');
    for (final feature in features) {
      list.write('<li>${escapeHtml(feature)}</li>');
    }
    list.write('</ul>');
    html = html.replaceAll('{{features}}', list.toString());
    return withInteractiveKit(html);
  }

  /// The coder model writes the whole page from the learner's description.
  /// Null when the model isn't installed, refuses, fails, or runs out of
  /// tokens before writing any visible content — the caller then falls back
  /// to the template for the classified type.
  Future<String?> _writeAppWithCoder(AppBuildIntent intent, int gen) async {
    final coderOk = await promptAndFetchCoderPackage(context, ref);
    if (!coderOk || !mounted) return null;
    try {
      final engine = await ref.read(programmingEngineProvider.future);
      final html = await AiCoderService(engine: engine).generateAppHtml(
        intent: intent,
        maxTokens: kAppFreeTextBuildMaxTokens,
        onToken: (cumulative) {
          if (!mounted || gen != _buildGen) return;
          setState(
            () => _buildNote = trFill(
              context,
              'Writing a custom version… {n} characters so far',
              {'n': '${cumulative.length}'},
            ),
          );
        },
      );
      if (html == null || !hasVisibleContent(html)) return null;
      return html;
    } catch (e) {
      debugPrint('free-text app build failed: $e');
      return null;
    }
  }

  /// The ready-made design for the app type paints at once, so the learner
  /// never waits on the model. A described app then gets a custom page from
  /// the coder in the background ([_upgradeWithCoder]).
  Future<void> _buildApp() async {
    if (_appType == null) return;
    if (!mounted) return;
    final gen = ++_buildGen;

    setState(() {
      _building = true;
      _buildNote = tr(context, 'Building your app…');
      // A fresh build is a different app from whatever was last saved.
      _projectId = null;
      _savedLabel = null;
    });

    final intent = _currentIntent();
    final fromDescription = intent.description.isNotEmpty;
    final images = _pendingImages;
    var html = await _assembleAppHtml(intent);
    if (!mounted || gen != _buildGen) return;
    if (images.isNotEmpty) {
      html = applyPickedImages(html, images, heading: tr(context, 'Gallery'));
    }
    _codeController.text = html;
    _builtTitle = null;

    final ready = fromDescription
        ? tr(
            context,
            'Here is a first version to try straight away. I am writing a '
            'custom one from your description and will swap it in when it is '
            'ready. 🎉',
          )
        : tr(
            context,
            'Your app preview is ready! 🎉 Toggle Preview / Code to view or edit.',
          );

    setState(() {
      _messages.add(_ChatMsg(ready, true));
      _building = false;
      _showStudio = true;
      _buildNote = '';
      _pendingImages = const [];
      _upgrading = fromDescription;
      // The chat is ready for the next idea once this one is built.
      _choosingType = true;
    });
    _scrollDown();
    // Every build is a project: saved straight away into Projects ›
    // Applications, with its own backend.
    await _saveToProjects();
    if (fromDescription && mounted && gen == _buildGen) {
      await _upgradeWithCoder(gen, intent, images, html);
    }
  }

  /// Swaps the coder's page in for the ready-made [shown] one, into the
  /// same project folder. If the learner already changed the code, it asks
  /// first instead of overwriting their work.
  Future<void> _upgradeWithCoder(
    int gen,
    AppBuildIntent intent,
    List<PickedImage> images,
    String shown,
  ) async {
    final started = DateTime.now();
    final generated = await _writeAppWithCoder(intent, gen);
    debugPrint(
      'App build: custom page '
      '${generated == null ? 'not written' : 'written'} in '
      '${DateTime.now().difference(started).inMilliseconds} ms',
    );
    if (!mounted || gen != _buildGen) return;
    setState(() {
      _upgrading = false;
      _buildNote = '';
    });
    if (generated == null) {
      showInstructionNoticeSnack(
        context,
        tr(
          context,
          "I couldn't write a custom version this time — keep going with "
          'this design and change it with the bar under the code.',
        ),
      );
      return;
    }
    var html = generated;
    if (images.isNotEmpty) {
      html = applyPickedImages(html, images, heading: tr(context, 'Gallery'));
    }
    void useIt() {
      if (!mounted || gen != _buildGen) return;
      _builtTitle = extractPageTitle(html);
      _replaceCode(html, undo: _codeController.text);
      setState(() {});
    }

    if (_codeController.text == shown) {
      useIt();
      showInstructionAppliedSnack(
        context,
        onUndo: _undoLastInstruction,
        message: tr(context, 'Your custom app is ready.'),
      );
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'Your custom app is ready. Using it replaces your changes.',
            ),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 12),
          action: SnackBarAction(
            label: tr(context, 'Use it'),
            onPressed: useIt,
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: const AppBarBackButton(),
        title: Row(
          children: [
            const Icon(Icons.phone_android, size: 20, color: AppColors.primary),
            const SizedBox(width: 8),
            Text(tr(context, 'App Builder')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => context.push('/applab'),
            child: Text(tr(context, 'Lessons')),
          ),
          if (_showStudio) ...[
            PopupMenuButton<String>(
              tooltip: tr(context, 'More'),
              enabled: !_exporting,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'backend') _viewBackend();
                if (value == 'export') _exportProject();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'backend',
                  child: Row(
                    children: [
                      const Icon(Icons.dns_outlined, size: 18),
                      const SizedBox(width: 10),
                      Text(tr(context, 'View project files')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Row(
                    children: [
                      const Icon(Icons.ios_share_outlined, size: 18),
                      const SizedBox(width: 10),
                      Text(tr(context, 'Export project (.zip)')),
                    ],
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: () => setState(() => _showStudio = false),
              child: Text(tr(context, 'Back to chat')),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.18),
              ),
            ),
            child: Text(
              tr(
                context,
                _showStudio
                    ? 'Edit the code on the left — the preview on the right updates as you type. Use Reload or Full screen in the preview bar.'
                    : 'Describe the app you want and OTIC writes it — the screens '
                          'and a backend that saves its data. Prefer choosing? Tap ☰ '
                          'to pick from a list.',
              ),
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
          if (_showStudio) ...[
            ProjectToolsBar(
              savedLabel: _savedLabel,
              saving: _saving,
              onSave: _saveToProjects,
              onPictures: _addPictures,
              onStyle: _openStyle,
              onOpenProjects: () => context.push('/projects'),
            ),
            Expanded(
              child: LiveHtmlStudio(
                key: _studioKey,
                controller: _codeController,
                onApply: _applyCodeEdits,
                toolbar: CodeInstructionBar(
                  busy: _autocorrectBusy,
                  onSubmit: _applyInstruction,
                  onPickImages: () => pickPictures(context),
                  onSubmitWithImages: _applyImageInstruction,
                ),
              ),
            ),
          ] else
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                itemCount: _messages.length,
                itemBuilder: (_, i) {
                  final msg = _messages[i];
                  return _ChatBubble(text: msg.text, isBot: msg.isBot);
                },
              ),
            ),
          if (_building || _upgrading)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _buildNote.isNotEmpty
                          ? _buildNote
                          : _upgrading
                          ? tr(context, 'Writing a custom version of your app…')
                          : tr(context, 'Building your app...'),
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  ),
                ],
              ),
            ),
          if (!_showStudio && !_building)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
                color: Theme.of(context).colorScheme.surface,
              ),
              padding: const EdgeInsets.fromLTRB(8, 10, 12, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_choosingType && _pendingImages.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 0, 6),
                      child: InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 18),
                        label: Text(
                          trFill(
                            context,
                            '{n} picture(s) will go on your app',
                            {'n': '${_pendingImages.length}'},
                          ),
                        ),
                        onDeleted: () =>
                            setState(() => _pendingImages = const []),
                      ),
                    ),
                  Row(
                    children: [
                      if (_choosingType) ...[
                        IconButton(
                          tooltip: tr(context, 'Pick from a list'),
                          onPressed: _pickFromList,
                          icon: const Icon(Icons.list_alt_outlined),
                        ),
                        IconButton(
                          tooltip: tr(context, 'Add pictures'),
                          onPressed: _attachPictures,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                        ),
                      ],
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          onSubmitted: (_) => _onSend(),
                          minLines: 1,
                          maxLines: _choosingType ? 4 : 1,
                          decoration: InputDecoration(
                            hintText: _choosingType
                                ? tr(context, 'Describe your app…')
                                : tr(context, 'Type your answer...'),
                            border: InputBorder.none,
                          ),
                          textInputAction: TextInputAction.send,
                        ),
                      ),
                      IconButton.filled(
                        onPressed: _onSend,
                        icon: const Icon(Icons.arrow_upward),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatMsg {
  const _ChatMsg(this.text, this.isBot);
  final String text;
  final bool isBot;
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.text, required this.isBot});
  final String text;
  final bool isBot;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isBot ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isBot
              ? Theme.of(context).colorScheme.surface
              : AppColors.primary,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isBot ? 4 : 16),
            topRight: Radius.circular(isBot ? 16 : 4),
            bottomLeft: const Radius.circular(16),
            bottomRight: const Radius.circular(16),
          ),
          border: isBot
              ? Border.all(color: Theme.of(context).dividerColor)
              : null,
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isBot
                ? Theme.of(context).colorScheme.onSurface
                : Colors.white,
            height: 1.5,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
