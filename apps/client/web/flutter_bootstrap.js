{{flutter_js}}
{{flutter_build_config}}

// Flutter's deprecated cleanup worker unregisters itself and reloads clients.
// Registering it on every launch can repeatedly interrupt startup and verification.
_flutter.loader.load();
