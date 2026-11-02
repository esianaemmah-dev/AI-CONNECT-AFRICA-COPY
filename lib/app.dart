import 'package:shared_preferences/shared_preferences.dart';
import 'shared/widgets/staff_session_scope.dart';
import 'features/learn/class_learning_panel.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ai_core/model/model_manager.dart';
import 'ai_core/providers/ai_provider.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_provider.dart';
import 'db/providers/db_provider.dart';
import 'features/model_setup/model_not_installed_screen.dart';
import 'l10n/app_locale.dart';
import 'l10n/language_provider.dart';
import 'services/model_fetch_service.dart';
import 'services/notes/note_quiz_builder.dart';
import 'services/notes/note_text_indexer.dart';
import 'services/storage_housekeeper.dart';

class OticApp extends ConsumerStatefulWidget {
  const OticApp({super.key});

  @override
  ConsumerState<OticApp> createState() => _OticAppState();
}

class _OticAppState extends ConsumerState<OticApp> {
  bool _ready = false;
  bool _didWarmTranslate = false;
  bool _didRunHousekeeping = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!kIsWeb) {
      final db = ref.read(dbProvider);
      await db.customStatement('UPDATE admin_identity SET pin_plain = NULL');
      await db.customStatement('UPDATE teacher_profiles SET pin_plain = NULL');
    }
    await (await SharedPreferences.getInstance()).remove('teacher_pin_plain');
    // Small delay to let Flutter render the splash first
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      final persisted = await readPersistedLearningLanguage();
      Object? student;
      try {
        student = await ref.read(activeStudentProvider.future);
      } catch (_) {}
      if (mounted && student == null && persisted != null) {
        ref.read(languageOverrideProvider.notifier).adoptSaved(persisted);
      }
    } catch (e) {
      debugPrint('OticApp language seed failed: $e');
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _warmTranslationPipeline() async {
    try {
      await ref.read(translationPipelineProvider.future);
    } catch (e) {
      debugPrint('ensureTranslationPipeline failed: $e');
    }
  }

  /// Runs once per app launch, well after startup — a proxy for "idle"
  /// rather than real OS idle-callback detection (Flutter has no portable
  /// one across Android/Windows/Linux). A cold model load already keeps the
  /// device busy for the first several seconds; waiting this long out means
  /// the sweep's own disk I/O never competes with that or with the first
  /// screen's own first paint.
  Future<void> _runHousekeeping() async {
    // Load the brain (and warm its prompt cache) now, while the learner is
    // still looking at the home screen, so the first question doesn't wait
    // for it. Nothing happens when no model is installed.
    unawaited(_warmChat());
    await Future.delayed(const Duration(seconds: 8));
    if (!mounted) return;
    try {
      final db = ref.read(dbProvider);
      final report = await StorageHousekeeper(db).runSweep();
      if (report.removed > 0) {
        debugPrint(
          'StorageHousekeeper: ${report.expiredSessions} chat(s) '
          'aged out past ${kChatHistoryRetention.inDays} days, '
          '${report.orphanedFiles} orphaned file(s) removed.',
        );
      }
    } catch (e) {
      debugPrint('StorageHousekeeper kickoff failed: $e');
    }
    // PDF pages not read yet, and quiz questions for note topics not
    // finished last time (or written per page, before topics). Quiz writing
    // uses the brain, so it starts later still: a learner's first questions
    // after launch must not queue behind it.
    if (mounted) unawaited(ref.read(noteTextIndexerProvider).resumePending());
    await Future.delayed(const Duration(minutes: 2));
    if (mounted) unawaited(ref.read(noteQuizBuilderProvider).resumePending());
  }

  Future<void> _warmChat() async {
    try {
      final info = await ref.read(modelInfoProvider.future);
      if (!info.isReady || !mounted) return;
      await ref.read(chatInferencePipelineProvider.future);
    } catch (e) {
      debugPrint('Chat warm-up failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const _SplashScreen(),
      );
    }

    final router = ref.watch(appRouterProvider);
    // Same value the translation engine routes on — see appLanguageProvider.
    final languageCode = ref.watch(appLanguageProvider);
    ref.listen<String>(appLanguageProvider, (prev, next) {
      if (next != 'en') unawaited(_warmTranslationPipeline());
    });
    if (!_didWarmTranslate) {
      _didWarmTranslate = true;
      if (languageCode != 'en') {
        unawaited(_warmTranslationPipeline());
      }
    }
    if (!_didRunHousekeeping) {
      _didRunHousekeeping = true;
      unawaited(_runHousekeeping());
    }
    return MaterialApp.router(
      title: 'AI Connect Africa',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      locale: const Locale('en'),
      supportedLocales: const [Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        return AppLocale(
          languageCode: languageCode,
          child: StaffSessionScope(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkTheme.bgBottom,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/branding/ai-connect-africa-logo.png',
              width: 80,
              height: 80,
            ),
            const SizedBox(height: 24),
            Text(
              'AI Connect Africa',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.darkTheme.textPrimary,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Gates the Learn screen: shows "model not installed" if no model found.
/// "Try demo mode" reveals [child] for this visit without installing
/// anything — the chat provider already falls back to canned demo answers
/// when no model is loaded, so this just lets that path be reached.
///
/// On Android fat APKs, [modelInfoProvider] waits while bundled models are
/// streamed out of APK assets into app storage (one-time).
class ModelGate extends ConsumerStatefulWidget {
  const ModelGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends ConsumerState<ModelGate> {
  bool _showDemoAnyway = false;

  @override
  Widget build(BuildContext context) {
    if (_showDemoAnyway) return widget.child;

    final bootstrap = ref.watch(bundledModelsBootstrapProvider);
    final modelInfo = ref.watch(modelInfoProvider);
    final packagesReady = ref.watch(classroomPackagesReadyProvider);

    final unpacking =
        bootstrap.isLoading ||
        (bootstrap.hasValue &&
            bootstrap.value!.extractedAnything &&
            modelInfo.isLoading);

    if (bootstrap.isLoading || unpacking || packagesReady.isLoading) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Preparing your workspace…',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Initializing offline classroom systems...',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return modelInfo.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => widget.child,
      data: (info) {
        final missingChat = info.status == ModelStatus.notInstalled;
        final missingPackages = packagesReady.valueOrNull != true;
        if (missingChat || missingPackages) {
          final err = bootstrap.asData?.value.error;
          return Column(
            children: [
              const ClassLearningPanel(),
              Expanded(
                child: ModelNotInstalledScreen(
                  info: info,
                  onTryDemo: () => setState(() => _showDemoAnyway = true),
                  bootstrapError: err,
                ),
              ),
            ],
          );
        }
        return widget.child;
      },
    );
  }
}
