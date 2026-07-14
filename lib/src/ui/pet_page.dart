import 'package:flutter/material.dart';

import '../core/pet/pet_controller.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class PetPage extends StatelessWidget {
  const PetPage({super.key, required this.controller});

  final PetController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pet = controller.selectedPet;
        return ListView(
          padding: AppTokens.pagePadding,
          children: [
            const SectionHeader(
              title: '宠物',
              subtitle: '管理宠物动作、触发规则与互动提示。',
            ),
            const SizedBox(height: 12),
            _Panel(
              title: '当前宠物',
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final controls = [
                    SizedBox(
                      width:
                          constraints.maxWidth >= 650 ? 260 : double.infinity,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(pet.id),
                        initialValue: pet.id,
                        decoration: const InputDecoration(labelText: '宠物选择'),
                        items: [
                          for (final candidate in controller.pets)
                            DropdownMenuItem(
                                value: candidate.id,
                                child: Text(candidate.name)),
                        ],
                        onChanged: (value) {
                          if (value != null) controller.selectPet(value);
                        },
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示桌宠'),
                      value: controller.visible,
                      onChanged: controller.setVisible,
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('减少动画'),
                      value: controller.reducedMotion,
                      onChanged: controller.setReducedMotion,
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('桌宠语音静音'),
                      value: controller.muted,
                      onChanged: controller.setMuted,
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('忽略桌宠交互'),
                      subtitle: const Text('点击和滑动会直接操作下方界面。'),
                      value: controller.ignorePointer,
                      onChanged: controller.setIgnorePointer,
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('桌宠大小',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        SegmentedButton<double>(
                          segments: const [
                            ButtonSegment(value: 0.7, label: Text('极小')),
                            ButtonSegment(value: 0.85, label: Text('小')),
                            ButtonSegment(value: 1.0, label: Text('中')),
                            ButtonSegment(value: 1.15, label: Text('大')),
                            ButtonSegment(value: 1.3, label: Text('极大')),
                          ],
                          selected: {controller.scale},
                          onSelectionChanged: (value) =>
                              controller.setScale(value.first),
                        ),
                      ],
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.resetPosition,
                      icon: const Icon(Icons.my_location_outlined),
                      label: const Text('重置桌宠位置'),
                    ),
                  ];
                  return Wrap(spacing: 24, runSpacing: 8, children: controls);
                },
              ),
            ),
            const SizedBox(height: 14),
            _Panel(
              title: '动作',
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final action in pet.actions)
                    SizedBox(
                      width: 190,
                      child:
                          _ActionTile(action: action, controller: controller),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _Panel(
              title: '触发规则',
              child: Column(
                children: [
                  for (final rule in controller.rules) ...[
                    _RuleEditor(rule: rule, controller: controller),
                    const Divider(height: 18),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            _Panel(
              title: '对话与语音',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final voice in controller.voices)
                    OutlinedButton.icon(
                      onPressed: controller.muted
                          ? null
                          : () => controller.previewVoice(voice.asset),
                      icon: const Icon(Icons.volume_up_outlined),
                      label: Text(voice.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 100),
          ],
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action, required this.controller});

  final PetActionDefinition action;
  final PetController controller;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text(action.label,
                          style: Theme.of(context).textTheme.titleSmall)),
                  Switch.adaptive(
                    value: controller.enabledActionIds.contains(action.id),
                    onChanged: (value) =>
                        controller.setActionEnabled(action.id, value),
                  ),
                ],
              ),
              Text(
                '${action.loop ? '循环' : '单次'} · ${action.frameDuration.inMilliseconds}ms/帧',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => controller.previewAction(action.id),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('预览'),
              ),
            ],
          ),
        ),
      );
}

class _RuleEditor extends StatelessWidget {
  const _RuleEditor({required this.rule, required this.controller});

  final PetRule rule;
  final PetController controller;

  @override
  Widget build(BuildContext context) {
    final actions = controller.selectedPet.actions;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final fields = [
          SizedBox(
            width: wide ? 150 : double.infinity,
            child: Text(rule.trigger.label,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          SizedBox(
            width: wide ? 150 : double.infinity,
            child: DropdownButtonFormField<String>(
              key: ValueKey('${rule.trigger.name}-${rule.actionId}'),
              initialValue: rule.actionId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '动作'),
              items: [
                for (final action in actions)
                  DropdownMenuItem(
                    value: action.id,
                    child: Text(action.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  controller.updateRule(rule.copyWith(actionId: value));
                }
              },
            ),
          ),
          SizedBox(
            width: wide ? 260 : double.infinity,
            child: TextFormField(
              key: ValueKey('${rule.trigger.name}-${rule.bubbleText}'),
              initialValue: rule.bubbleText,
              maxLength: 36,
              decoration:
                  const InputDecoration(labelText: '气泡文字', counterText: ''),
              onChanged: (value) =>
                  controller.updateRule(rule.copyWith(bubbleText: value)),
            ),
          ),
          SizedBox(
            width: wide ? 330 : double.infinity,
            child: DropdownButtonFormField<String>(
              key: ValueKey('${rule.trigger.name}-${rule.voiceAsset}'),
              initialValue: rule.voiceAsset ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '语音'),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('不播放语音', overflow: TextOverflow.ellipsis),
                ),
                for (final voice in controller.voices)
                  DropdownMenuItem(
                    value: voice.asset,
                    child: Text(voice.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => controller.updateRule(
                rule.copyWith(
                  voiceAsset: value,
                  clearVoice: value == null || value.isEmpty,
                ),
              ),
            ),
          ),
          Switch.adaptive(
            value: rule.enabled,
            onChanged: (value) =>
                controller.updateRule(rule.copyWith(enabled: value)),
          ),
          OutlinedButton.icon(
            onPressed: () => controller.trigger(rule.trigger, force: true),
            icon: const Icon(Icons.play_circle_outline_rounded),
            label: const Text('测试'),
          ),
        ];
        return Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: fields);
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
}
