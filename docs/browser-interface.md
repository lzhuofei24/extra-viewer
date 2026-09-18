# Shared browsing interface

Directory and classification use CollectionBrowserPage. Rules retain their own
query controller but share BrowserPageScaffold, BrowserToolbar,
BrowserSelectionBar and BrowserEntitySliver with those pages.

- Floating chrome belongs to BrowserPageScaffold. Top and bottom clearance is
  part of the scroll content so content can pass beneath the glass surfaces.
- BrowserToolbar capabilities hide unsupported operations. The rule home has
  no immersive mode or file sorting. Built-in results show a fixed-sort label.
- The options popup uses the same FloatingGlassSurface as navigation. Its
  Material menu has no fill, tint or shadow and does not clip the glass edge.
  Do not introduce a separate backdrop/opacity implementation for this popup.
  Set independentBackdrop for overlays: OverlayPortal retains the toolbar's
  inherited nested-glass flag, which otherwise disables popup blur/refraction.
- BrowserEntitySliver is the single implementation for equal-height,
  equal-width, square and the three list styles. BrowserScrollShell owns bounded
  preheating, scroll pagination and visible-entity selection registration.
- RuleBrowserController owns rule definitions, result pages and temporary sort.
  Request generations discard obsolete successes and failures. The app shell
  retains the controller across navigation and owns its disposal.
- Rule sorting never writes shared browser sorting preferences. Layout, theme
  and display preferences remain shared. Rule selection coordinates with the
  shell's Mini player; protected built-ins cannot be edited or deleted.
- Empty directory/classification covers use EmptyFolderCover without disk
  generation. Text-only lists do not instantiate preview widgets.

Management orders its sections as all materials (directory, classification,
rules), then recoverable tasks. Each material heading has an add button, including
empty sections. Portrait uses two columns and landscape uses four. Each item has
one operations menu: update, rename and delete. Directory update scans files,
classification update rebuilds covers and custom-rule update edits the rule.
Protected favorites retain update but cannot be renamed/deleted; built-in rules
cannot be changed.

No database or preview-file schema changes are required by this UI refactor.
