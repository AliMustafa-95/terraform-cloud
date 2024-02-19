# Create an organization if specified
resource "tfe_organization" "org" {
  count = var.create_new_organization ? 1 : 0
  name  = var.organization_name
  email = var.organization_email
}

# Import organization data from the JSON file
locals {
  # Set the organization name depending on whether it's a new org or existing
  organization_name = var.create_new_organization ? tfe_organization.org[0].id : var.organization_name

  # Import org data from json file
  org_data = jsondecode(file(var.config_file_path))

  # Extract workspace data
  raw_workspaces = try(local.org_data.workspaces, [])

  # Normalize the workspace data
  workspaces = [for workspace in local.raw_workspaces : {
    name                = workspace["name"]
    description         = try(workspace["description"], "No description provided.")
    teams               = try(workspace["teams"], [])
    terraform_version   = try(workspace["terraform_version"], "~> 1.0")
    tag_names           = try(workspace["tag_names"], [])
    auto_apply          = try(workspace["auto_apply"], false)
    allow_destroy_plan  = try(workspace["auto_apply"], true) # Fix typo here
    execution_mode      = try(workspace["execution_mode"], "remote")
    speculative_enabled = try(workspace["speculative_enabled"], true)
    vcs_repo            = try(workspace["vcs_repo"], {})
  }]

  # Create a single workspace for project configurations
  project_config_workspace = {
    "project_config-ws" => {
      name                = "project_config-ws"
      description         = "Workspace for managing project configurations"
      teams               = [] # Initially no teams assigned
      terraform_version   = "~> 1.0"
      auto_apply          = false
      allow_destroy_plan  = true
      execution_mode      = "remote"
      speculative_enabled = true
      vcs_repo            = {} # Define your VCS repository details
    }
  }

  # Filter out the project workspaces
  project_workspaces = { for workspace in local.workspaces : workspace["name"] => workspace if workspace["name"] != "project_config-ws" }
}

# Create project workspaces
resource "tfe_workspace" "projects" {
  for_each            = local.project_workspaces
  name                = each.value.name
  description         = each.value.description
  organization        = var.organization_name
  terraform_version   = each.value.terraform_version
  tag_names           = each.value.tag_names
  auto_apply          = each.value.auto_apply
  allow_destroy_plan  = each.value.allow_destroy_plan
  execution_mode      = each.value.execution_mode
  speculative_enabled = each.value.speculative_enabled

  dynamic "vcs_repo" {
    for_each = each.value.vcs_repo != {} ? toset(["1"]) : toset([])

    content {
      identifier     = each.value.vcs_repo["identifier"]
      oauth_token_id = each.value.vcs_repo["oauth_token_id"]
    }
  }

  # Associate project workspaces with project_config-ws
  depends_on = [tfe_workspace.project_config]
}

# Create the project_config-ws workspace
resource "tfe_workspace" "project_config" {
  for_each            = local.project_config_workspace
  name                = each.value.name
  description         = each.value.description
  organization        = local.organization_name
  terraform_version   = each.value.terraform_version
  auto_apply          = each.value.auto_apply
  allow_destroy_plan  = each.value.allow_destroy_plan
  execution_mode      = each.value.execution_mode
  speculative_enabled = each.value.speculative_enabled

  dynamic "vcs_repo" {
    for_each = each.value.vcs_repo != {} ? toset(["1"]) : toset([])

    content {
      identifier     = each.value.vcs_repo["identifier"]
      oauth_token_id = each.value.vcs_repo["oauth_token_id"]
    }
  }
}

# Create teams
resource "tfe_team" "teams" {
  # Create a map of teams from the list stored in JSON using the 
  # team name as the key
  for_each     = { for team in local.teams : team["name"] => team }
  name         = each.key
  organization = local.organization_name
  visibility   = each.value["visibility"]

  # Create a single organization_access block if value isn't an empty map
  dynamic "organization_access" {
    for_each = each.value["organization_access"] != {} ? toset(["1"]) : toset([])

    content {
      # Get the value for each permission if it exists, set to false if it doesn't
      manage_policies         = try(each.value.organization_access["manage_policies"], false)
      manage_policy_overrides = try(each.value.organization_access["manage_policy_overrides"], false)
      manage_workspaces       = try(each.value.organization_access["manage_workspaces"], false)
      manage_vcs_settings     = try(each.value.organization_access["manage_vcs_settings"], false)
    }
  }
}

# Configure workspace access for teams
resource "tfe_team_access" "team_access" {
  for_each     = { for access in local.workspace_team_access : "${access.workspace_name}_${access.team_name}" => access }
  access       = each.value["access_level"]
  team_id      = tfe_team.teams[each.value["team_name"]].id
  workspace_id = tfe_workspace.projects[each.value["workspace_name"]].id
}

# Add TFC accounts to the organization
resource "tfe_organization_membership" "org_members" {
  for_each     = toset(flatten(local.teams.*.members))
  organization = local.organization_name
  email        = each.value
}

locals {
  # Create a list of member mappings like this
  # team_name = team_name
  # member_name = member_email
  team_members = flatten([
    for team in local.teams : [
      for member in team["members"] : {
        team_name   = team["name"]
        member_name = member
      } if length(team["members"]) > 0
    ]
  ])
}

resource "tfe_team_organization_member" "team_members" {
  # Create a map with the team name and member name combines as a key for uniqueness
  for_each                   = { for member in local.team_members : "${member.team_name}_${member.member_name}" => member }
  team_id                    = tfe_team.teams[each.value["team_name"]].id
  organization_membership_id = tfe_organization_membership.org_members[each.value["member_name"]].id
}