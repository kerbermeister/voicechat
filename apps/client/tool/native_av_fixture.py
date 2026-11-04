"""Temporarily compile the synthetic native source into an integration-test app."""
from contextlib import contextmanager
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlparse


@contextmanager
def native_av_fixture(root, device, android_abi=None):
    client = root / 'apps/client'
    fixtures = client / 'integration_test'
    if device == 'macos':
        main = client / 'macos/Runner/MainFlutterWindow.swift'
        before = main.read_bytes()
        anchor = 'RegisterGeneratedPlugins(registry: flutterViewController)'
        assert before.decode().count(anchor) == 1
        after = before.decode().replace(anchor, anchor + '\n    NativeAVMarker.install(flutterViewController.engine.binaryMessenger)')
        patches = {main: (before, (after + '\n' + (fixtures / 'native_av_marker.swift').read_text()).encode())}
    else:
        if android_abi not in ('arm64-v8a', 'x86_64'):
            raise ValueError('Native A/V fixture requires a supported emulator ABI')
        main = client / 'android/app/src/main/kotlin/dev/voicechat/voicechat_probe/MainActivity.kt'
        before = main.read_bytes()
        anchor = 'super.configureFlutterEngine(flutterEngine)'
        assert before.decode().count(anchor) == 1
        after = before.decode().replace(anchor, anchor + '\n        NativeAVMarker.install(flutterEngine.dartExecutor.binaryMessenger)')
        gradle = client / 'android/app/build.gradle.kts'
        config = client / '.dart_tool/package_config.json'
        plugin = next(package for package in json.loads(config.read_text())['packages'] if package['name'] == 'flutter_webrtc')
        plugin_root = (config.parent / unquote(urlparse(plugin['rootUri']).path)).resolve()
        version = re.search(r"implementation 'io.github.webrtc-sdk:android:([\d.]+)'", (plugin_root / 'android/build.gradle').read_text())[1]
        gradle_before = gradle.read_bytes()
        assert gradle_before.decode().count('dependencies {') == 1
        gradle_after = gradle_before.decode().replace('dependencies {', f'dependencies {{\n    debugImplementation("io.github.webrtc-sdk:android:{version}")')
        gradle_after += '\nandroid { buildTypes.getByName("debug") { ndk { abiFilters.clear(); abiFilters.add("' + android_abi + '") } } }\n'
        other_abis = {'arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'} - {android_abi}
        excluded = ', '.join('"lib/' + abi + '/**"' for abi in sorted(other_abis))
        gradle_after += '\nandroid { packaging { jniLibs { excludes += setOf(' + excluded + ') } } }\n'
        # Cargokit otherwise adds x86 and x64 to every debug build, even on
        # an arm64-only fixture. Keep the same crypto sources for the owned ABI.
        cargo_platform = {'arm64-v8a': 'android-arm64', 'x86_64': 'android-x64'}[android_abi]
        gradle_after += ('\ngradle.projectsEvaluated {\n'
                         '    project(":flutter_vodozemac").tasks.named("cargokitCargoBuildFlutter_vodozemacDebug").configure {\n'
                         '        withGroovyBuilder { setProperty("targetPlatforms", listOf("' + cargo_platform + '")) }\n'
                         '    }\n}\n')
        native = client / 'android/app/src/debug/kotlin/dev/voicechat/voicechat_probe/NativeAVMarker.kt'
        assert not native.exists()
        patches = {main: (before, after.encode()), gradle: (gradle_before, gradle_after.encode()),
                   native: (None, (fixtures / 'NativeAVMarker.kt').read_bytes())}
    changed = subprocess.check_output(['git', 'status', '--porcelain', '--', *[str(path) for path in patches]],
                                      cwd=root, text=True)
    if changed:
        raise RuntimeError('Native fixture requires clean app entry points; refusing to overwrite changes')
    applied = []
    try:
        for path, (_, after) in patches.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(after)
            applied.append(path)
        yield
    finally:
        if any(path.read_bytes() != patches[path][1] for path in applied):
            raise RuntimeError('An instrumented app file changed during the probe; refusing to overwrite it')
        for path in reversed(applied):
            before = patches[path][0]
            if before is None:
                path.unlink()
            else:
                path.write_bytes(before)
