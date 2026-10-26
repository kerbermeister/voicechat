{{flutter_js}}
{{flutter_build_config}}

// Do not gate startup on the deprecated worker's unbounded getRegistration().
// The SDK's cleanup worker can also navigate clients when upgrading an old worker.
_flutter.loader.load({
  config: {}, // voicechat-versioned-assets
  onEntrypointLoaded: async (engineInitializer) => {
    try {
      window.voicechatStartup?.mark?.('entrypoint');
      window.voicechatStartup?.stage('Подготавливаем приложение…');
      const appRunner = await engineInitializer.initializeEngine();
      window.voicechatStartup?.mark?.('engine');
      await appRunner.runApp();
      window.voicechatStartup?.mark?.('run-app');
    } catch (_) {
      window.voicechatStartup?.fail();
    }
  },
}).catch(() => window.voicechatStartup?.fail());
