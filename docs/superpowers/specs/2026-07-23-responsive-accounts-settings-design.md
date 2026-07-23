# Responsive Accounts Settings

## Problem

The Accounts pane is a non-scrolling vertical stack. When the account list is
taller than the Settings window, lower accounts and footer actions cannot be
reached. Each account also uses one wide horizontal row, so account details and
button labels become unreadable as the window narrows.

## Design

The Accounts pane will own a vertical scroll container that covers its
description, account list, footer actions, and CodexBar notice. Scrolling must
work with a mouse wheel, trackpad, and accessibility scroll actions without
changing account state.

Each account will keep the current horizontal presentation when the detail
column is wide enough. At constrained widths it will switch to a stacked
presentation:

1. Account identity, ownership, activity, routing, quota, sign-in, reset-credit,
   and automatic-reset protection information appears together.
2. Priority and active state appear in a compact control row.
3. Routing, activation, reset, and account-management actions appear below with
   their full labels whenever the minimum Settings width permits.

The compact layout may wrap text vertically but must not hide a control or
require horizontal scrolling. Existing bindings, confirmation dialogs,
accessibility labels, OAuth state, routing state, reset protection, and reset
availability remain unchanged.

## Scope

This change is limited to Accounts Settings layout and window-size behavior. It
does not change routing selection, account persistence, quota handling, reset
behavior, or the other Settings panes.

## Verification

- Add a regression seam for choosing wide versus compact account-row layout and
  prove its boundary behavior before implementing the view change.
- Run the focused layout tests, complete Swift suite, application build,
  release-tool checks, and diff validation.
- Install the verified bundle reversibly.
- In the native app, verify the Accounts pane at default and minimum window
  sizes, scroll from the first account through the footer, and confirm full
  action labels remain usable without invoking account or reset actions.
