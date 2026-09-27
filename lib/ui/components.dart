import 'package:material_ui/material_ui.dart';

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.color,
    this.padding = 24,
    this.radius = 28,
  });
  final Widget child;
  final Color? color;
  final double padding, radius;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: EdgeInsets.all(padding), child: child),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

String dateLabel(DateTime value) {
  final d = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}.${two(d.month)}.${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    this.body,
  });
  final IconData icon;
  final String title;
  final String? body;
  @override
  Widget build(BuildContext context) => Panel(
    child: SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 20),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (body != null) ...[
            const SizedBox(height: 12),
            Text(body!, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}
