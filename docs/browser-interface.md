# Shared browsing interface

Directory and classification use CollectionBrowserPage. Rules retain their own
query controller but share BrowserPageScaffold, BrowserToolbar,
BrowserSelectionBar and BrowserEntitySliver with those pages.

- BrowserNodeGridSliver and IndexNodePreviewCard render all three home grids.
  Rule covers reuse the latest visual entity thumbnail from the default-sorted,
  capped result set. The read worker batches cover queries; missing thumbnails
  use the existing preview pipeline, and failed previews keep a type placeholder.
- Directory and classification keep independent in-session BrowserLocationSession
  snapshots, with PageStorage scroll positions. Navigation invalidates earlier
  requests and publishes either a complete cached page or a target loading state.
  Missing nodes fall back to the nearest surviving ancestor; source availability
  is not used as evidence of node deletion.
- The toolbar add action reuses management creation flows. Directory and rule
  results hide it; classification children create a child under the current node.

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
empty sections. There is no separate page title or description. Portrait uses
two columns and landscape uses four, with 72dp cards that grow with text scale.
Each item has
one operations menu: update, rename and delete. Directory update scans files,
classification update rebuilds covers and custom-rule update edits the rule.
Protected favorites retain update but cannot be renamed/deleted; built-in rules
cannot be changed.

No database or preview-file schema changes are required by this UI refactor.
