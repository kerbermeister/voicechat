import 'package:flutter/material.dart';
import 'route_coordinator.dart';

class RouteStatusBanner extends StatelessWidget {
  final RouteCoordinator coordinator;
  final bool syncOnline;
  const RouteStatusBanner({
    super.key,
    required this.coordinator,
    required this.syncOnline,
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<RouteState>(
    stream: coordinator.changes,
    initialData: coordinator.state,
    builder: (context, _) {
      final busy =
          coordinator.state == RouteState.checking ||
          coordinator.state == RouteState.recovering;
      final String message;
      if (coordinator.state == RouteState.closed) {
        return const SizedBox.shrink();
      }
      if (busy) {
        message = 'Восстанавливаем соединение';
      } else if (coordinator.route(RouteService.matrix) == null ||
          !syncOnline) {
        message = 'Нет связи · сообщения сохраняются в зашифрованной очереди';
      } else if (coordinator.route(RouteService.control) == null) {
        message = 'Сервис звонков временно недоступен';
      } else {
        return const SizedBox.shrink();
      }
      final colors = Theme.of(context).colorScheme;
      return Material(
        color: colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  style: TextStyle(color: colors.onSecondaryContainer),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: colors.onSecondaryContainer,
                  minimumSize: const Size(88, 48),
                ),
                onPressed: busy ? null : coordinator.recover,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
