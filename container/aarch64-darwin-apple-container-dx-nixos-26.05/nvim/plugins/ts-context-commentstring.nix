# WP7.7 (docs/reviews/2026-09-29-fable.md finding C7): the pinned NixVim has
# a typed module for this plugin, so it no longer belongs under
# extra_plugins/ (that directory's admission rule -- see undotree.nix -- is
# "no upstream NixVim module exists"). This used to also call
# `require('Comment').setup({ pre_hook = ... })` directly, a second,
# untracked `setup()` on top of the one `plugins.comment.enable` already
# emits (nvim/plugins/comment.nix) -- whichever ran last silently won.
# `plugins.comment.settings.pre_hook` there is now the only place pre_hook
# is set.
{
  plugins.ts-context-commentstring.enable = true;
}
