{{flutter_js}}
{{flutter_build_config}}

// Do not gate startup on the deprecated worker's unbounded getRegistration().
// The SDK's cleanup worker can also navigate clients when upgrading an old worker.
_flutter.loader.load({
  onEntrypointLoaded: async (engineInitializer) => {
    try {
      window.voicechatStartup?.stage('Подготавливаем приложение…');
      const appRunner = await engineInitializer.initializeEngine();
      await appRunner.runApp();
    } catch (_) {
      window.voicechatStartup?.fail();
    }
  },
}).catch(() => window.voicechatStartup?.fail());
