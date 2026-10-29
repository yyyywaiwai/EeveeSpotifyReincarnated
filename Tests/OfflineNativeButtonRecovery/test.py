#!/usr/bin/env python3
"""Host-only source invariants for the playlist ActionView re-hide retry."""

from pathlib import Path
import unittest


SOURCE = (Path(__file__).resolve().parents[2] / 'Sources/EeveeSpotify/Offline/'
          'OfflineNativeSingleAlbumButton.x.swift').read_text()


def between(start: str, end: str) -> str:
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class PlaylistRehideSourceTests(unittest.TestCase):
    def test_existing_scheduled_visits_retry_without_catalog_refetch(self):
        prepare = between('static func prepare(on host:', 'private static func currentState(')
        self.assertLess(prepare.index('if let binding = state.binding'),
                        prepare.index('guard !state.attempted'))
        self.assertLess(prepare.index('bulk.reconcileScheduledAppearance'),
                        prepare.index('OfflineCollectionCatalog.fetch(uri: uri)'))
        self.assertIn('if kind == .playlist, let bulk = binding as? BulkBinding', prepare)

    def test_recovery_is_pinned_to_exact_active_page_and_owner(self):
        reconcile = between('func reconcileScheduledAppearance(',
                            'private func revealPlaylistPreservingEnabled(')
        for gate in ('collection.kind == .playlist', 'host === currentHost',
                     'appearanceEpoch == epoch', 'associated === self',
                     'currentState(host: currentHost, state: state', 'isCurrentPage()'):
            self.assertIn(gate, reconcile)
        self.assertNotIn('OfflineCollectionCatalog.fetch', reconcile)

    def test_temporary_enable_is_always_restored(self):
        reveal = between('private func revealPlaylistPreservingEnabled(',
                         'func refreshIndex()')
        self.assertLess(reveal.index('let wasEnabled = button.isEnabled'),
                        reveal.index('button.isEnabled = true'))
        self.assertIn('defer { button.isEnabled = wasEnabled }', reveal)
        self.assertIn('playlistRevealAndValidate(', reveal)

    def test_hidden_retry_keeps_binding_and_visible_unsafe_state_deactivates(self):
        bulk = between('private final class BulkBinding:', 'static func prepare(on host:')
        presentation = bulk.split('private func updatePresentation() {', 1)[1].split(
            'let job = OfflineNativeSingleAlbumButton.activeBatch', 1)[0]
        self.assertIn('if playlistAction == nil { deactivate() }', presentation)
        self.assertIn('if action.isHidden {', presentation)
        self.assertIn('guard revealPlaylistPreservingEnabled(', presentation)
        self.assertIn('playlistGeometryPostSafe(', presentation)
        self.assertIn('deactivate(); return', presentation)

    def test_pending_or_unsafe_playlist_does_not_handle_tap(self):
        bulk = between('private final class BulkBinding:', 'static func prepare(on host:')
        tap = bulk.split('func handleTap() -> Bool {', 1)[1].split('private func updatePresentation()', 1)[0]
        self.assertIn('guard revealed, let action = playlistAction, !action.isHidden', tap)
        self.assertIn('playlistGeometryPostSafe(', tap)

    def test_late_hide_retries_only_exact_live_playlist_binding(self):
        hook = between('class OfflineNativePlaylistActionVisibilityHook:',
                       'func activateOfflineNativeSingleAlbumButton()')
        self.assertLess(hook.index('orig.setHidden(hidden)'),
                        hook.index('scheduleHiddenPlaylistReconcile(for: target)'))
        self.assertIn('if hidden && target.isHidden', hook)
        visibility_activation = between('static func activateVisibilityHookIfNeeded()',
                                        'static func beginAppearance(')
        self.assertIn('class_getInstanceMethod(playlistAction, Selector(("setHidden:")))',
                      visibility_activation)
        schedule = between('static func scheduleHiddenPlaylistReconcile(for action:',
                           'private static func currentState(')
        for gate in ('Thread.isMainThread', 'findNativeButton(in: action',
                     'as? BulkBinding', 'binding.playlistAction === action',
                     'binding.scheduleHiddenReconcile()'):
            self.assertIn(gate, schedule)
        bulk = between('private final class BulkBinding:', 'static func prepare(on host:')
        retry = bulk.split('func scheduleHiddenReconcile() {', 1)[1].split(
            'private func revealPlaylistPreservingEnabled(', 1)[0]
        for gate in ('!lateReconcilePending', 'DispatchQueue.main.async',
                     'self.active', 'self.playlistAction?.isHidden == true',
                     'self.reconcileScheduledAppearance('):
            self.assertIn(gate, retry)
        self.assertEqual(retry.count('self.lateReconcilePending = false'), 1)
        self.assertIn('defer { self.lateReconcilePending = false }', retry)
        self.assertLess(retry.index('defer { self.lateReconcilePending = false }'),
                        retry.index('self.reconcileScheduledAppearance('))
        self.assertNotIn('OfflineCollectionCatalog.fetch', retry)

    def test_visibility_hook_activation_does_not_gate_existing_download_hooks(self):
        page_hook = between('class OfflineNativeAlbumPageHook:',
                            'class OfflineNativeGranularActionHook:')
        owner_hook = between('class OfflineNativeGranularActionHook:',
                             'class OfflineNativePlaylistActionVisibilityHook:')
        visibility_hook = between('class OfflineNativePlaylistActionVisibilityHook:',
                                  'func activateOfflineNativeSingleAlbumButton()')
        self.assertIn('typealias Group = OfflineNativeSingleAlbumButtonGroup', page_hook)
        self.assertIn('typealias Group = OfflineNativeSingleAlbumButtonGroup', owner_hook)
        self.assertIn('typealias Group = OfflineNativePlaylistActionVisibilityGroup',
                      visibility_hook)
        activation = between('func activateOfflineNativeSingleAlbumButton()',
                             'private enum OfflineNativeSingleAlbumButton')
        base_gate = activation.split('else { return }', 1)[0]
        self.assertNotIn('OfflineNativePlaylistActionVisibilityHook.targetName', base_gate)
        self.assertLess(activation.index('OfflineNativeSingleAlbumButtonGroup().activate()'),
                        activation.index('OfflineNativeSingleAlbumButton.activateVisibilityHookIfNeeded()'))
        visibility_activation = between('static func activateVisibilityHookIfNeeded()',
                                        'static func beginAppearance(')
        self.assertIn('guard Thread.isMainThread, !visibilityHookActivated',
                      visibility_activation)
        self.assertIn('NSClassFromString(playlistActionClass)', visibility_activation)
        self.assertLess(visibility_activation.index('visibilityHookActivated = true'),
                        visibility_activation.index('OfflineNativePlaylistActionVisibilityGroup().activate()'))
        binding = between('private static func bindCollection(', 'static func detach(')
        self.assertLess(binding.index('let found = playlistGeometryPreflight('),
                        binding.index('activateVisibilityHookIfNeeded()'))
        self.assertLess(binding.index('activateVisibilityHookIfNeeded()'),
                        binding.index('let binding = BulkBinding('))


if __name__ == '__main__':
    unittest.main()
