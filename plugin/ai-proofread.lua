if vim.g.loaded_ai_proofread then
  return
end
vim.g.loaded_ai_proofread = true

vim.api.nvim_create_user_command("AIProofread", function()
  require("ai-proofread").review()
end, {
  desc = "Review the current buffer with AI Proofread",
})

vim.api.nvim_create_user_command("AIProofreadSelection", function()
  require("ai-proofread").review_selection()
end, {
  desc = "Review the last visual selection with AI Proofread",
})

vim.api.nvim_create_user_command("AIProofreadCancel", function()
  require("ai-proofread").cancel()
end, {
  desc = "Cancel the current AI Proofread request",
})

vim.api.nvim_create_user_command("AIProofreadHealth", function()
  require("ai-proofread").health()
end, {
  desc = "Check the AI Proofread configuration",
})

vim.api.nvim_create_user_command("AIProofreadApply", function(args)
  if args.range > 0 then
    require("ai-proofread").apply(args.line1, args.line2)
  else
    require("ai-proofread").apply()
  end
end, {
  desc = "Apply the current AI Proofread correction",
  range = true,
})

vim.api.nvim_create_user_command("AIProofreadApplyAll", function()
  require("ai-proofread").apply_all()
end, {
  desc = "Apply all AI Proofread corrections",
})

vim.api.nvim_create_user_command("AIProofreadIgnore", function()
  require("ai-proofread").ignore()
end, {
  desc = "Ignore the current AI Proofread correction",
})

local legacy_commands = {
  FoundationReview = "review",
  FoundationReviewSelection = "review_selection",
  FoundationReviewCancel = "cancel",
  FoundationReviewHealth = "health",
  FoundationReviewApply = "apply",
  FoundationReviewApplyAll = "apply_all",
  FoundationReviewIgnore = "ignore",
}

for command, method in pairs(legacy_commands) do
  vim.api.nvim_create_user_command(command, function()
    require("ai-proofread")[method]()
  end, {
    desc = "Deprecated alias for AI Proofread",
  })
end
