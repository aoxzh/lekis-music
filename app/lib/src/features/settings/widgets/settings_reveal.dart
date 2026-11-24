import 'package:material_ui/material_ui.dart';

class SettingsReveal extends InheritedWidget {
  const SettingsReveal({
    super.key,
    required this.target,
    required this.request,
    required super.child,
  });

  final Key target;
  final Object request;

  static Widget control(BuildContext context, Widget child, {Key? key}) {
    final reveal = context.dependOnInheritedWidgetOfExactType<SettingsReveal>();
    if (reveal == null || reveal.target != (key ?? child.key)) {
      return child;
    }
    return _RevealedControl(key: ObjectKey(reveal.request), child: child);
  }

  @override
  bool updateShouldNotify(SettingsReveal oldWidget) =>
      request != oldWidget.request;
}

class _RevealedControl extends StatefulWidget {
  const _RevealedControl({super.key, required this.child});

  final Widget child;

  @override
  State<_RevealedControl> createState() => _RevealedControlState();
}

class _RevealedControlState extends State<_RevealedControl> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scrollable.ensureVisible(context, alignment: 0.25);
    });
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.primary),
      borderRadius: BorderRadius.circular(8),
    ),
    child: widget.child,
  );
}
