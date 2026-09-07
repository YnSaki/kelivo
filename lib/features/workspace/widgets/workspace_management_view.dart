import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/workspace_provider.dart';
import '../pages/workspace_detail_page.dart';
import '../pages/workspace_list_page.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

/// Workspace management view shared by the desktop settings pane and the
/// storage page workspaces category detail: root location card on top, then a
/// master-detail layout (workspace list on the left, detail on the right).
class WorkspaceManagementView extends StatefulWidget {
  const WorkspaceManagementView({super.key, this.onDataChanged});

  /// Fired after mutations that affect storage usage (workspace deletion,
  /// root relocation) so hosts can refresh their usage report.
  final VoidCallback? onDataChanged;

  @override
  State<WorkspaceManagementView> createState() =>
      _WorkspaceManagementViewState();
}

class _WorkspaceManagementViewState extends State<WorkspaceManagementView> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final wp = context.watch<WorkspaceProvider>();
    final items = wp.workspaces;

    // Selection fallback: deleted workspace -> first item (mirrors the
    // providers pane's `_nextKeyAfterRemoval` behavior).
    if (_selectedId == null || items.every((w) => w.id != _selectedId)) {
      _selectedId = items.isNotEmpty ? items.first.id : null;
    }

    final detail = _selectedId == null
        ? Center(
            child: Text(
              l10n.workspaceListEmpty,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          )
        : WorkspaceDetailPage(
            key: ValueKey('workspace-detail-$_selectedId'),
            workspaceId: _selectedId!,
            embedded: true,
          );

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WorkspacesLocationCard(onDataChanged: widget.onDataChanged),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 256,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: WorkspaceListPage(
                              embedded: true,
                              selectedId: _selectedId,
                              onOpenWorkspace: (ws) =>
                                  setState(() => _selectedId = ws.id),
                              onDataChanged: widget.onDataChanged,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IosIconButton(
                              icon: Lucide.Plus,
                              size: 16,
                              minSize: 28,
                              semanticLabel: l10n.workspaceAdd,
                              onTap: () async {
                                final ws = await showAddWorkspaceDialog(
                                  context,
                                );
                                if (ws != null && mounted) {
                                  setState(() => _selectedId = ws.id);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    VerticalDivider(
                      width: 24,
                      color: cs.onSurface.withValues(alpha: 0.08),
                    ),
                    Expanded(child: detail),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the current `@workspaces` host directory and opens the relocation
/// dialog (desktop only; `workspaces_dir_v1` is honored on desktop targets).
class _WorkspacesLocationCard extends StatelessWidget {
  const _WorkspacesLocationCard({required this.onDataChanged});

  final VoidCallback? onDataChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final wp = context.watch<WorkspaceProvider>();
    final path = wp.rootPath ?? '';

    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.08),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Lucide.FolderOpen,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.storageMountsWorkspacesLocationTitle,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              IosTileButton(
                label: l10n.storageMountsWorkspacesLocationDialogTitle,
                icon: Lucide.Pencil,
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => const _WorkspacesLocationDialog(),
                  );
                  if (ok == true) onDataChanged?.call();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            path,
            style: TextStyle(
              fontSize: 12.5,
              fontFamily: 'monospace',
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            l10n.storageMountsWorkspacesNote,
            style: TextStyle(
              fontSize: 11.5,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop-only dialog to relocate the `@workspaces` root. New locations are
/// validated against the sync scope (overlapping the backup/LAN-sync trees is
/// rejected) and against nesting inside the current sandbox.
class _WorkspacesLocationDialog extends StatefulWidget {
  const _WorkspacesLocationDialog();

  @override
  State<_WorkspacesLocationDialog> createState() =>
      _WorkspacesLocationDialogState();
}

class _WorkspacesLocationDialogState extends State<_WorkspacesLocationDialog> {
  String? _path;
  bool _moveFiles = true;
  String? _error;
  bool _saving = false;

  Future<void> _pick() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _path = result;
      _error = null;
    });
  }

  String? _localizedError(String code) {
    final l10n = AppLocalizations.of(context)!;
    switch (code) {
      case WorkspaceProvider.errorPathInvalid:
        return l10n.storageMountsErrorPathInvalid;
      case WorkspaceProvider.errorSyncOverlap:
        return l10n.storageMountsErrorSyncOverlap;
      case WorkspaceProvider.errorInsideWorkspaces:
        return l10n.storageMountsErrorInsideWorkspaces;
      case WorkspaceProvider.errorDestinationNotEmpty:
        return l10n.storageMountsErrorDestinationNotEmpty;
      default:
        // Unknown codes still surface — never silently no-op.
        return code;
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final path = _path;
    if (path == null || path.isEmpty) {
      setState(() => _error = l10n.storageMountsErrorPathInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final String? err;
    try {
      err = await context.read<WorkspaceProvider>().setWorkspacesRootLocation(
        path,
        moveFiles: _moveFiles,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = l10n.storageMountsWorkspacesMoveFailed('$e');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      final errorMessage = _localizedError(err);
      setState(() => _error = errorMessage);
      return;
    }
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: _moveFiles
            ? l10n.storageMountsWorkspacesMoved(path)
            : l10n.storageMountsWorkspacesLocationChanged,
        type: NotificationType.success,
      );
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l10n.storageMountsWorkspacesLocationDialogTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.storageMountsWorkspacesLocationTitle,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _path ?? context.watch<WorkspaceProvider>().rootPath ?? '',
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                IosTileButton(
                  label: l10n.storageMountsPickButton,
                  icon: Lucide.FolderOpen,
                  onTap: _pick,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.storageMountsWorkspacesMoveFilesLabel,
                    style: TextStyle(fontSize: 13.5, color: cs.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                IosSwitch(
                  value: _moveFiles,
                  onChanged: (v) => setState(() => _moveFiles = v),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(fontSize: 12.5, color: cs.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.homePageCancel),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(l10n.homePageDone),
        ),
      ],
    );
  }
}
