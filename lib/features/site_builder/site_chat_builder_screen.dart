import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
import '../../shared/widgets/code_instruction_bar.dart';
import '../../shared/widgets/html_preview.dart';
import '../../services/projects/project_providers.dart';
import '../create/dev_l10n.dart';
import '../projects/scaffold/project_scaffold.dart';
import '../projects/widgets/image_instruction_runner.dart';
import '../projects/widgets/project_tools_bar.dart';
import '../projects/widgets/project_saved_notice.dart';
import '../settings/coder_package_prompt.dart';
import 'site_build_coder.dart';
import 'site_template_catalog.dart';
import 'site_template_classifier.dart';
import 'site_template_picker.dart';
import '../../shared/widgets/studio_page.dart';

/// Longest description passed into the coder brief — leaves room in
/// `kCoderMaxPromptChars` for the system prompt and the rest of the brief.
const _kMaxDescriptionChars = 800;

// ── Chat messages ────────────────────────────────────────────────────────────

class _ChatMsg {
  const _ChatMsg(this.text, this.isBot);
  final String text;
  final bool isBot;
}

// ── Screen ───────────────────────────────────────────────────────────────────

class SiteChatBuilderScreen extends ConsumerStatefulWidget {
  const SiteChatBuilderScreen({super.key});

  @override
  ConsumerState<SiteChatBuilderScreen> createState() =>
      _SiteChatBuilderScreenState();
}

class _SiteChatBuilderScreenState extends ConsumerState<SiteChatBuilderScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _codeController = TextEditingController();
  final _studioKey = GlobalKey<LiveHtmlStudioState>();
  final List<_ChatMsg> _messages = [];
  final Map<String, String> _answers = {};

  /// Auto-picked template copy, locked in before Build so the coder sees it.
  final Map<String, String> _recordedContent = {};

  SiteTemplateEntry? _template;
  int _fieldIndex = -1;

  /// Waiting for the learner to describe a site (or pick one from the list).
  bool _choosingTemplate = true;
  bool _choosingColor = false;
  String _colorTheme = '';
  bool _building = false;
  bool _showStudio = false;
  String _buildNote = '';

  /// The coder is writing a custom page while the learner already has the
  /// ready-made design on screen (see [_upgradeWithCoder]).
  bool _upgrading = false;

  /// Bumped by every build and wizard reset, so a custom page that arrives
  /// late never lands on a newer site.
  int _buildGen = 0;

  /// English form of the learner's description, when this build came from
  /// free text. Empty on the guided (pick-from-list) path.
  String _description = '';

  /// Page title of the last free-text build, fixed at build time so later
  /// edits don't rename the project folder on every save.
  String? _builtTitle;

  /// Pictures attached before Build, placed on the page once it exists.
  List<PickedImage> _pendingImages = const [];

  /// Code as it stood before the last AI change, so it can be reverted.
  String? _undoSnapshot;
  bool _autocorrectBusy = false;

  /// This build's folder under Projects › Websites, once saved. A rebuild or
  /// edit re-saves into the same folder instead of making a new one.
  String? _projectId;
  String? _savedLabel;
  bool _savingProject = false;

  static const _colorThemes = {
    '1': {'name': 'Default', 'primary': null, 'bg': null},
    '2': {'name': 'Ocean Blue', 'primary': '#2563eb', 'bg': '#eff6ff'},
    '3': {'name': 'Forest Green', 'primary': '#059669', 'bg': '#ecfdf5'},
    '4': {'name': 'Royal Purple', 'primary': '#7c3aed', 'bg': '#f5f3ff'},
    '5': {'name': 'Sunset Orange', 'primary': '#ea580c', 'bg': '#fff7ed'},
    '6': {'name': 'Rose Pink', 'primary': '#e11d48', 'bg': '#fff1f2'},
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startIntro());
  }

  Future<void> _startIntro() async {
    await _sayBot(
      "Hi! Tell me about the website you want, in your own words. 🚀\n\n"
      "Say what it's for and what should be on it — for example: "
      "\"a website for my football club with fixtures, players and a contact form\".\n\n"
      "I'll write the site for you. You can add pictures with the 🖼 button, "
      "or tap ☰ to pick from a list instead.",
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

    // Numbers/template names match in English; free-text answers stay as typed.
    final english = await localizeDevStudent(ref, text);
    if (!mounted) return;

    if (_choosingTemplate) {
      await _handleDescription(english);
    } else if (_choosingColor) {
      await _handleColorChoice(english);
    } else if (_fieldIndex >= 0 && _template != null) {
      await _handleFieldAnswer(text);
    }
  }

  Future<void> _handleColorChoice(String text) async {
    final lower = text.trim();
    String? key;
    for (final k in _colorThemes.keys) {
      if (lower.contains(k) ||
          lower.toLowerCase().contains(
            _colorThemes[k]!['name']!.toLowerCase(),
          )) {
        key = k;
        break;
      }
    }
    key ??= '1';

    _colorTheme = key;
    _choosingColor = false;
    _fieldIndex = 0;

    final name = _colorThemes[key]!['name'];
    await _sayBot(
      "$name theme selected! ✨\n\nNow just ${_template!.askFields.length} quick questions:",
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _askCurrentField();
  }

  /// Clears what a previous build recorded, so a new description or list
  /// pick starts from nothing.
  void _resetWizard() {
    _answers.clear();
    _recordedContent.clear();
    _fieldIndex = -1;
    _colorTheme = '';
    _choosingColor = false;
    _description = '';
    _builtTitle = null;
    _buildGen++;
    _upgrading = false;
  }

  /// Free-text entry: the description is the whole spec. It is classified
  /// locally (no model call) only to pick a fallback template; the page
  /// itself is written by the coder model.
  Future<void> _handleDescription(String english) async {
    final text = english.trim();
    if (text.split(RegExp(r'\s+')).length < 3) {
      await _sayBot(
        "Tell me a little more — what is the website for, and what should be "
        "on it? Or tap ☰ to pick from a list.",
      );
      return;
    }
    _resetWizard();
    _template = classifySiteTemplate(text);
    _description = text.length > _kMaxDescriptionChars
        ? text.substring(0, _kMaxDescriptionChars)
        : text;
    _colorTheme = _colorKeyMentionedIn(text) ?? '1';
    _choosingTemplate = false;
    await _sayBot("Got it! ✍️ Writing your website now…");
    await _buildSite();
  }

  /// A colour the learner named in their description ("a green site…").
  String? _colorKeyMentionedIn(String text) {
    final lower = text.toLowerCase();
    for (final e in _colorThemes.entries) {
      if (e.value['primary'] == null) continue;
      final word = e.value['name']!.toLowerCase().split(' ').last;
      if (RegExp('\\b$word\\b').hasMatch(lower)) return e.key;
    }
    return null;
  }

  Future<void> _attachPictures() async {
    final picked = await pickPictures(context);
    if (picked.isEmpty || !mounted) return;
    setState(() => _pendingImages = [..._pendingImages, ...picked]);
  }

  /// Guided entry: the list picker, then the original colour → details
  /// questions and the template build, with no model call.
  Future<void> _pickFromList() async {
    if (_building) return;
    final chosen = await showSiteTemplatePicker(context);
    if (chosen == null || !mounted) return;
    _resetWizard();
    _addUser(chosen.name);
    _template = chosen;
    _choosingTemplate = false;
    _choosingColor = true;

    await _sayBot("Great choice — ${chosen.name}! 🎨\n\nPick a color theme:");
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await _sayBot(
      "① Default (template colors)\n② Ocean Blue 🔵\n③ Forest Green 🟢\n④ Royal Purple 🟣\n⑤ Sunset Orange 🟠\n⑥ Rose Pink 🩷\n\nType a number!",
    );
  }

  Future<void> _askCurrentField() async {
    if (_template == null || _fieldIndex >= _template!.askFields.length) return;
    final field = _template!.askFields[_fieldIndex];
    await _sayBot("${field.question}\n\n💡 ${field.hint}");
  }

  Future<void> _handleFieldAnswer(String text) async {
    final field = _template!.askFields[_fieldIndex];
    final answer = text.trim();
    _answers[field.key] = answer;
    _fieldIndex++;

    if (_fieldIndex >= _template!.askFields.length) {
      _recordAutoContent();
      final recorded = tr(
        context,
        'Perfect! All features recorded. ✅ Building your site…',
      );
      setState(() => _messages.add(_ChatMsg(recorded, true)));
      _scrollDown();
      await _buildSite();
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _askCurrentField();
    }
  }

  /// Lock auto-picked copy into the intent before the coder runs.
  void _recordAutoContent() {
    _recordedContent.clear();
    if (_template == null) return;
    for (final entry in _template!.autoFields.entries) {
      _recordedContent[entry.key] = pickSiteAutoField(entry.value);
    }
  }

  SiteBuildIntent _currentIntent() {
    final theme = _colorThemes[_colorTheme];
    return SiteBuildIntent(
      templateId: _template!.id,
      templateName: _template!.name,
      themeName: theme?['name'] ?? 'Default',
      themePrimary: theme?['primary'],
      answers: Map<String, String>.from(_answers),
      content: Map<String, String>.from(_recordedContent),
      description: _description,
    );
  }

  /// The template fallback for a free-text build that the model couldn't
  /// write. The free-text path records no answers or copy (so none leaks into
  /// the model's brief), but a template needs every token filled — use the
  /// questions' example answers and the template's sample copy.
  SiteBuildIntent _fallbackIntent(SiteBuildIntent intent) {
    final template = _template!;
    return SiteBuildIntent(
      templateId: intent.templateId,
      templateName: intent.templateName,
      themeName: intent.themeName,
      themePrimary: intent.themePrimary,
      answers: {
        for (final f in template.askFields)
          f.key: f.hint.replaceFirst(RegExp(r'^e\.g\.\s*'), ''),
        ...intent.answers,
      },
      content: {
        for (final e in template.autoFields.entries)
          e.key: pickSiteAutoField(e.value),
        ...intent.content,
      },
      description: intent.description,
    );
  }

  /// Maps the learner's answers + recorded copy onto the matching static
  /// template. Every value is HTML-escaped — a `<` or `&` typed into a
  /// business name or phone number must render as text, not markup.
  Future<String> _assembleTemplateHtml(SiteBuildIntent intent) async {
    var html = await rootBundle.loadString(
      'assets/templates/${intent.templateId}.html',
    );
    for (final e in intent.answers.entries) {
      html = html.replaceAll('{{${e.key}}}', escapeHtml(e.value));
    }
    for (final e in intent.content.entries) {
      html = html.replaceAll('{{${e.key}}}', escapeHtml(e.value));
    }
    if (intent.themePrimary != null) {
      final colorCSS =
          '<style>:root{--primary:${intent.themePrimary}} '
          'header,nav,.btn,[class*=hero]{background:${intent.themePrimary}!important} '
          '.btn{background:${intent.themePrimary}!important}</style>';
      html = html.replaceFirst('</head>', '$colorCSS</head>');
    }
    return html;
  }

  void _applyCodeEdits() {
    // LiveHtmlStudio already mirrors the controller; this keeps a hard refresh hook.
    setState(() {});
    if (_projectId != null) _saveToProjects(quiet: true);
  }

  Future<void> _undoLastInstruction() async {
    final previous = _undoSnapshot;
    if (previous == null) return;
    _undoSnapshot = null;
    _codeController.text = previous;
    _studioKey.currentState?.applyNow();
    if (_projectId != null) await _saveToProjects(quiet: true);
  }

  /// Runs a free-form instruction ("center the text", "change color to
  /// blue") through the coder model and, on success, repaints the preview
  /// immediately — no separate manual "Apply" tap needed for an AI edit.
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
            "That didn't change the site — try saying where the picture should go.",
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

  /// Swaps the page for [html] (keeping [undo] for the Undo snackbar),
  /// repaints the preview and re-saves the project if it was saved already.
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

  String get _siteTitle {
    for (final key in const [
      'business_name',
      'company_name',
      'school_name',
      'salon_name',
      'org_name',
      'name',
      'title',
    ]) {
      final v = _answers[key]?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    final built = _builtTitle;
    if (built != null && built.isNotEmpty) return built;
    return _template?.name ?? 'My website';
  }

  /// Writes the site as a full project (frontend + backend + docs) under
  /// Projects › Websites. [quiet] skips the snackbar for auto-saves after
  /// small edits.

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
    if (mounted) setState(() => _savingProject = true);
    try {
      while (_saveAgain && mounted) {
        _saveAgain = false;
        final loud = _saveLoud;
        _saveLoud = false;
        last = await _saveOnce(quiet: !loud) ?? last;
      }
    } finally {
      if (mounted) setState(() => _savingProject = false);
    }
    return last;
  }

  Future<ProjectFolder?> _saveOnce({required bool quiet}) async {
    if (_template == null) return null;
    final html = _codeController.text;
    if (html.trim().isEmpty) return null;
    try {
      final intent = _currentIntent();
      final images = <String, Uint8List>{};
      final files = buildWebsiteProject(
        title: _siteTitle,
        html: html,
        templateName: intent.templateName,
        siteContent: {...intent.content, ...intent.answers},
        images: images,
      );
      final saved = await saveCreation(
        ref,
        kind: ProjectKind.website,
        title: _siteTitle,
        files: files,
        binaryFiles: images,
        projectId: _projectId,
        source: 'site_builder',
        template: intent.templateId,
        templateName: intent.templateName,
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
      debugPrint('site project save failed: $e');
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

  /// The coder model writes the whole site from the learner's description.
  /// Null when the model isn't installed, refuses, fails, or runs out of
  /// tokens before writing any visible content — the caller then falls back
  /// to the template for the classified site type.
  Future<String?> _writeSiteWithCoder(SiteBuildIntent intent, int gen) async {
    final coderOk = await promptAndFetchCoderPackage(context, ref);
    if (!coderOk || !mounted) return null;
    try {
      final engine = await ref.read(programmingEngineProvider.future);
      final html = await AiCoderService(engine: engine).generateSiteHtml(
        intent: intent,
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
      debugPrint('free-text site build failed: $e');
      return null;
    }
  }

  /// Every site paints at once from its template, so the learner never
  /// waits on the model. A described site then gets a custom page from the
  /// coder in the background ([_upgradeWithCoder]); one picked from the list
  /// needs no model call at all.
  Future<void> _buildSite() async {
    if (_template == null) return;
    if (!mounted) return;
    final gen = ++_buildGen;

    setState(() {
      _building = true;
      _buildNote = tr(context, 'Building your site…');
      // A new build is a new site — it gets its own folder, never
      // overwriting the one built before it.
      _projectId = null;
      _savedLabel = null;
    });

    final intent = _currentIntent();
    final fromDescription = intent.description.isNotEmpty;
    final images = _pendingImages;
    var html = await _assembleTemplateHtml(
      fromDescription ? _fallbackIntent(intent) : intent,
    );
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
            'Your website is ready! 🎉 Toggle Preview / Code to view or edit.',
          );

    setState(() {
      _messages.add(_ChatMsg(ready, true));
      _building = false;
      _showStudio = true;
      _buildNote = '';
      _pendingImages = const [];
      _upgrading = fromDescription;
      // The chat is ready for the next idea once this one is built.
      _choosingTemplate = true;
    });
    _scrollDown();
    // Every build is a project: saved straight away into Projects › Websites.
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
    SiteBuildIntent intent,
    List<PickedImage> images,
    String shown,
  ) async {
    final started = DateTime.now();
    final generated = await _writeSiteWithCoder(intent, gen);
    debugPrint(
      'Site build: custom page '
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
        message: tr(context, 'Your custom website is ready.'),
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
              'Your custom website is ready. Using it replaces your changes.',
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
            const Icon(Icons.language, size: 20, color: AppColors.primary),
            const SizedBox(width: 8),
            // Flexible + ellipsis: a longer translation (e.g. Luganda) plus
            // the two action buttons beside it can exceed the AppBar's title
            // width by a couple of pixels — pre-existing, only surfaced now
            // that this screen is actually reachable under those languages.
            Flexible(
              child: Text(
                tr(context, 'Website Builder'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_showStudio)
            TextButton(
              onPressed: () => setState(() => _showStudio = false),
              child: Text(tr(context, 'Back to chat')),
            ),
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
                    : 'Describe the website you want and OTIC writes it for you. '
                          'Prefer choosing? Tap ☰ to pick a ready-made design from a list.',
              ),
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),

          if (_showStudio) ...[
            ProjectToolsBar(
              savedLabel: _savedLabel,
              saving: _savingProject,
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
          ] else ...[
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
          ],

          if (_building || _upgrading)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
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
                          ? tr(context, 'Writing a custom version of your website…')
                          : tr(context, 'Building your site...'),
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
                  if (_choosingTemplate && _pendingImages.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 0, 6),
                      child: InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 18),
                        label: Text(
                          trFill(
                            context,
                            '{n} picture(s) will go on your site',
                            {'n': '${_pendingImages.length}'},
                          ),
                        ),
                        onDeleted: () =>
                            setState(() => _pendingImages = const []),
                      ),
                    ),
                  Row(
                    children: [
                      if (_choosingTemplate) ...[
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
                          maxLines: _choosingTemplate ? 4 : 1,
                          decoration: InputDecoration(
                            hintText: _choosingTemplate
                                ? tr(context, 'Describe your website…')
                                : tr(context, 'Type your answer...'),
                            border: InputBorder.none,
                          ),
                          textInputAction: TextInputAction.send,
                        ),
                      ),
                      const SizedBox(width: 8),
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

// ── Chat bubble ──────────────────────────────────────────────────────────────

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
