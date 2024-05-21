data "http" "myip" {
  url = "http://ipinfo.io/ip"
}

locals {
  myip = chomp(data.http.myip.response_body)
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.application_name}-${var.environment_name}-${var.location}"
  address_space       = ["${var.address_space}.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}
=============================================||================================
locals {
  repos        = [for repo_name, repo in var.repos : repo_name]
  project_name = endswith(lower(var.project_name), "-sandbox") ? regex("(.*)-.*$", var.project_name)[0] : var.project_name

  # For default reviewers, we need to have each reviewer for each path in the same resource. If we have a separate
  # resource for each reviewer/path, if one of the required reviewers opens a merge request, they will not be able to
  # merge it, as we prevent requestors from approving their changes by default, but they are a required approver.
  # The solution here- is to create a list of unique paths that need default reviewers, and create a separate
  # resource for each of them.
  # See ABC-xxxxx for more details around the reasoning for this.
  # 
  # The way that a unique list is being generated is via converting each list of paths to a string using `join`, taking
  # the resultant sha1 hash of that string, appending "-paths" to that hash, and setting that as an object's key. The
  # other value in the object is the list of path(s). All these objects get added to an array, which is deduped by the
  # `unique` function.
  # 
  # Then, we will combine all users for each path into one array, and add the resultant list as the required approvers.
  # 
  # TODO: we probably will need to do this for reviewers on specific branches as well
  default_reviewer_paths_users = {
    for default_reviewer_path in distinct(flatten([
      for default_reviewer in var.default_reviewers : [{
        key  = join("-", [sha1(join(",", default_reviewer["paths"])), "paths"])
        type = default_reviewer["type"]
        # If no paths are specified, just set the required approval on all paths
        paths = length(default_reviewer["paths"]) > 0 ? default_reviewer["paths"] : ["*"]
      }]
    ])) : default_reviewer_path.key => default_reviewer_path if default_reviewer_path["type"] == "user"
  }

  default_reviewers_users = {
    for default_reviewer in flatten([
      for default_reviewer_path_key, default_reviewer_path in local.default_reviewer_paths_users : [{
        key       = default_reviewer_path_key
        paths     = default_reviewer_path.paths
        type      = default_reviewer_path.type
        reviewers = default_reviewer_path.paths != tolist(["*"]) ? [for i, default_reviewer_var in var.default_reviewers : default_reviewer_var if default_reviewer_var["type"] == "user" && default_reviewer_var["paths"] == default_reviewer_path.paths].*.identifier : [for i, default_reviewer_var in var.default_reviewers : default_reviewer_var if default_reviewer_var["type"] == "user" && length(default_reviewer_var["paths"]) == 0].*.identifier
      }]
    ]) : default_reviewer.key => default_reviewer
  }

  # Do the same thing as above for AAD groups
  default_reviewer_paths_aad_groups = {
    for default_reviewer_path in distinct(flatten([
      for default_reviewer in var.default_reviewers : [{
        key  = join("-", [sha1(join(",", default_reviewer["paths"])), "paths"])
        type = default_reviewer["type"]
        # If no paths are specified, just set the required approval on all paths
        paths = length(default_reviewer["paths"]) > 0 ? default_reviewer["paths"] : ["*"]
      }]
    ])) : default_reviewer_path.key => default_reviewer_path if default_reviewer_path["type"] == "aad_group"
  }

  default_reviewers_aad_groups = {
    for default_reviewer in flatten([
      for default_reviewer_path_key, default_reviewer_path in local.default_reviewer_paths_aad_groups : [{
        key       = default_reviewer_path_key
        paths     = default_reviewer_path.paths
        type      = default_reviewer_path.type
        reviewers = default_reviewer_path.paths != tolist(["*"]) ? [for i, default_reviewer_var in var.default_reviewers : default_reviewer_var if default_reviewer_var["type"] == "aad_group" && default_reviewer_var["paths"] == default_reviewer_path.paths].*.identifier : [for i, default_reviewer_var in var.default_reviewers : default_reviewer_var if default_reviewer_var["type"] == "aad_group" && length(default_reviewer_var["paths"]) == 0].*.identifier
      }]
    ]) : default_reviewer.key => default_reviewer
  }

  protected_branches = {
    for protected_branch in flatten([
      for repo_name, repo in var.repos : [
        for protected_branch_name, protected_branch in repo.protected_branches : {
          key                    = "${repo_name}-${protected_branch_name}"
          repo                   = repo_name
          branch_name            = protected_branch_name
          num_approvals_required = protected_branch.num_approvals_required
        }
      ]
    ]) : protected_branch.key => protected_branch
  }

  protected_branch_reviewers = {
    for reviewer in flatten([
      for repo_name, repo in var.repos : [
        for protected_branch_name, protected_branch in repo.protected_branches : [
          for reviewer_name, reviewer in protected_branch.reviewers : {
            key         = "${repo_name}-${protected_branch_name}-${reviewer_name}"
            repo        = repo_name
            branch_name = protected_branch_name
            identifier  = reviewer.identifier
            type        = reviewer.type
            paths       = reviewer.paths
          }
        ]
      ]
    ]) : reviewer.key => reviewer
  }

  default_groups = toset([
    "Build Administrators",
    "Limited Project Administrators",
    "Contributors",
    "Project Administrators",
    "Readers"
  ])

  project_groups = setunion(local.default_groups, toset([for protected_branch_reviewer in local.protected_branch_reviewers : protected_branch_reviewer.identifier if protected_branch_reviewer.type == "project_group"]))

  ad_group_prefix = join("-", ["xxxx-gbl-aadg-ADO", local.project_name])

  default_group_access = {
    "Contributors" = join("-", [local.ad_group_prefix, "Contributors"])
  }

  group_access = merge(local.default_group_access,
    var.project_admins_enabled ? {
      "Project Administrators" = join("-", [local.ad_group_prefix, "Admins"])
    } : {},
    var.limited_project_admins_enabled ? {
      "Limited Project Administrators" = join("-", [local.ad_group_prefix, "Admins"])
    } : {},
    var.readers_enabled ? {
      "Readers" = join("-", [local.ad_group_prefix, "Readers"])
    } : {},
    var.build_admins_enabled ? {
      "Build Administrators" = join("-", [local.ad_group_prefix, "BuildAdmins"])
    } : {},
    var.release_admins_enabled ? {
      "Release Administrators" = join("-", [local.ad_group_prefix, "ReleaseAdmins"])
    } : {}
  )

  team_admins = var.project_teams != {} ? {
    for team_user in flatten([
      for team_name, team in var.project_teams : [
        for user_name, user in team.users : {
          key          = "${team_name}-${user_name}"
          team_name    = team_name
          access_level = user.access_level
          identifier   = user.identifier
          type         = user.type
        }
      ]
    ]) : team_user.key => team_user if team_user.access_level == "admin"
  } : {}

  team_members = var.project_teams != {} ? {
    for team_user in flatten([
      for team_name, team in var.project_teams : [
        for user_name, user in team.users : {
          key          = "${team_name}-${user_name}"
          team_name    = team_name
          access_level = user.access_level
          identifier   = user.identifier
          type         = user.type
        }
      ]
    ]) : team_user.key => team_user if team_user.access_level == "member"
  } : {}
}

data "azuredevops_group" "this" {
  for_each = local.project_groups

  project_id = azuredevops_project.this.id
  name       = each.value
}

data "azuredevops_git_repository" "this" {
  # By default, when a project is created, a repository with the same name is also created.
  # So, read this repository instead of creating it via `azuredevops_git_repository.this`
  for_each = contains(toset(local.repos), var.project_name) ? toset([var.project_name]) : toset([])

  project_id = azuredevops_project.this.id
  name       = each.value
}

data "azuredevops_git_repository" "wiki" {
  count = var.wiki_name != null ? 1 : 0

  project_id = azuredevops_project.this.id
  name       = var.wiki_name
}

data "azuread_group" "group_access" {
  for_each = local.group_access

  display_name = each.value
}

data "azuread_group" "aad_approvers" {
  for_each = toset(var.additional_aad_groups)

  display_name = each.value
}
------
resource "azuredevops_project" "this" {
  name               = var.project_name
  visibility         = "private"
  version_control    = "Git"
  work_item_template = var.project_work_item_template
  description        = var.project_description
  features = {
    "artifacts" = var.project_artifacts_enabled ? "enabled" : "disabled"
  }
}

# For all repositories in the xxxF organization, the default branch is named "main". This has been set in the console as, at the time of writing, this is not manageable with Terraform
resource "azuredevops_git_repository" "this" {
  # By default, when a project is created, a repository with the same name is also created. So, don't create a repository with that name
  for_each = setsubtract(toset(local.repos), [var.project_name])

  project_id = azuredevops_project.this.id
  name       = each.value
  initialization {
    init_type = "Uninitialized"
  }
  lifecycle {
    # Ignore changes to `initialization` block so existing repos can be imported
    ignore_changes = [
      initialization,
    ]
  }
}

# On PRs to the default branch of any repository, enforce two approvers, block author approval, and reset approvals on new pushes
resource "azuredevops_branch_policy_min_reviewers" "default" {
  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    reviewer_count                         = var.default_num_approvals_required
    submitter_can_vote                     = false
    last_pusher_cannot_approve             = true
    allow_completion_with_rejects_or_waits = false
    on_push_reset_all_votes                = true
    on_push_reset_approved_votes           = true

    scope {
      match_type = "DefaultBranch"
    }
  }
}

# On PRs to any protected branches in a specific repository, enforce two approvers, block author approval, and reset approvals on new pushes
resource "azuredevops_branch_policy_min_reviewers" "protected" {
  for_each = local.protected_branches

  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    reviewer_count                         = each.value.num_approvals_required
    submitter_can_vote                     = false
    last_pusher_cannot_approve             = true
    allow_completion_with_rejects_or_waits = false
    on_push_reset_all_votes                = true
    on_push_reset_approved_votes           = true

    scope {
      repository_id  = each.value.repo != var.project_name ? azuredevops_git_repository.this[each.value.repo].id : data.azuredevops_git_repository.this[each.value.repo].id
      repository_ref = "refs/heads/${each.value.branch_name}"
      match_type     = "Exact"
    }
  }
}

# On PRs to the default branch of any repository, ensure all comments have been resolved
resource "azuredevops_branch_policy_comment_resolution" "default" {
  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    scope {
      match_type = "DefaultBranch"
    }
  }
}

# On PRs to any protected branches in a specific repository, ensure all comments have been resolved
resource "azuredevops_branch_policy_comment_resolution" "protected" {
  for_each = local.protected_branches

  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    scope {
      repository_id  = each.value.repo != var.project_name ? azuredevops_git_repository.this[each.value.repo].id : data.azuredevops_git_repository.this[each.value.repo].id
      repository_ref = "refs/heads/${each.value.branch_name}"
      match_type     = "Exact"
    }
  }
}

# On PRs to the default branch of any repository, require specific users as approvers
resource "azuredevops_branch_policy_auto_reviewers" "default_users" {
  for_each = local.default_reviewers_users

  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    auto_reviewer_ids  = each.value.reviewers
    submitter_can_vote = false
    path_filters       = each.value.paths

    scope {
      match_type = "DefaultBranch"
    }
  }
}

# On PRs to the default branch of any repository, require specific AAD groups as approvers
resource "azuredevops_branch_policy_auto_reviewers" "default_aad_groups" {
  for_each = local.default_reviewers_aad_groups

  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    auto_reviewer_ids  = [for reviewer in each.value.reviewers : azuredevops_group.aad_approvers[reviewer].descriptor]
    submitter_can_vote = false
    path_filters       = each.value.paths

    scope {
      match_type = "DefaultBranch"
    }
  }
}

# On PRs to any protected branches in a specific repository, require specific approvers
resource "azuredevops_branch_policy_auto_reviewers" "protected" {
  for_each = local.protected_branch_reviewers

  project_id = azuredevops_project.this.id

  enabled  = true
  blocking = true

  settings {
    auto_reviewer_ids = [
      each.value.type == "project_group" ?
      data.azuredevops_group.this[each.value.identifier].origin_id :
      each.value.type == "aad_group" ?
      azuredevops_group.aad_approvers[each.value.identifier].descriptor :
      each.value.identifier
    ]
    submitter_can_vote = false
    path_filters       = lookup(each.value, "paths", ["*"])

    scope {
      repository_id  = each.value.repo != var.project_name ? azuredevops_git_repository.this[each.value.repo].id : data.azuredevops_git_repository.this[each.value.repo].id
      repository_ref = "refs/heads/${each.value.branch_name}"
      match_type     = "Exact"
    }
  }
}

# In order to add Azure AD groups as members to Azure DevOps groups, need to create a group with the origin as the Azure AD group ID,
# and then set the members of the Azure DevOps group to be the descriptor of this group
# Reference:
#   https://github.com/microsoft/terraform-provider-azuredevops/issues/313
#   https://github.com/microsoft/terraform-provider-azuredevops/issues/51#issuecomment-759217529
# 
# NOTE: cannot provide a limited scope when using `origin_id` (https://registry.terraform.io/providers/microsoft/azuredevops/latest/docs/resources/group#origin_id)
#   As such, this group will be created in the organization, rather than the project it refers to. A caveat with this is that, if a separate project tries to create
#   a group with the same origin_id, it will fail with a 50x error.
resource "azuredevops_group" "aad" {
  for_each = local.group_access

  origin_id = data.azuread_group.group_access[each.key].object_id
}

resource "azuredevops_group_membership" "this" {
  for_each = local.group_access

  group   = data.azuredevops_group.this[each.key].descriptor
  members = each.key == "Contributors" && var.project_teams != {} ? concat([azuredevops_group.aad[each.key].descriptor], [for team in azuredevops_team.this : team.descriptor]) : [azuredevops_group.aad[each.key].descriptor]

  # This will ensure that group membership is handled fully via code (i.e. anything done outside of code will be removed and replaced with what is in code)
  mode = "overwrite"
}

resource "azuredevops_group" "aad_approvers" {
  for_each = toset(var.additional_aad_groups)

  origin_id = data.azuread_group.aad_approvers[each.key].object_id
}

resource "azuredevops_team" "this" {
  for_each = var.project_teams

  project_id = azuredevops_project.this.id
  name       = each.key
  administrators = local.team_admins != {} ? [for team_admin in local.team_admins : team_admin.type == "project_group" ?
    data.azuredevops_group.this[team_admin.identifier].origin_id
  : team_admin.identifier] : []
  members = local.team_members != {} ? [for team_member in local.team_members : team_member.type == "project_group" ?
    data.azuredevops_group.this[team_member.identifier].origin_id
  : team_member.identifier] : []
}

# Give Default Groups except Readers a policy exemption when pushing to the Wiki to avoid needing to PR changes in
resource "azuredevops_git_permissions" "wiki_policy_exempt" {
  for_each = var.wiki_name != null ? setsubtract(local.default_groups, ["Readers"]) : []

  project_id    = azuredevops_project.this.id
  repository_id = data.azuredevops_git_repository.wiki[0].id
  principal     = data.azuredevops_group.this[each.key].id

  permissions = {
    PolicyExempt = "Allow"
  }
}

=============================================||================================
resource "azurerm_subnet" "application" {
  name                 = "snet-application"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["${var.address_space}.2.0/24"]
  service_endpoints    = ["Microsoft.Sql", "Microsoft.KeyVault", "Microsoft.Storage", "Microsoft.ContainerRegistry"]
  delegation {
    name = "application-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}
