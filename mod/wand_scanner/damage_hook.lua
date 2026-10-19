-- Attached to enemies by the Wand Scanner mod. Adds up damage the player deals and
-- hands the running total to the mod through a game global (hook scripts can't share tables).
function damage_received(damage, message, entity_thats_responsible, is_fatal, projectile_thats_responsible)
  if damage <= 0 then return end -- negative = healing
  local mine = entity_thats_responsible ~= 0 and EntityHasTag(entity_thats_responsible, "player_unit")
  if not mine and projectile_thats_responsible ~= 0 then
    -- some damage is credited to the projectile rather than the shooter; follow it back
    local pc = EntityGetFirstComponentIncludingDisabled(projectile_thats_responsible, "ProjectileComponent")
    local shooter = pc and ComponentGetValue2(pc, "mWhoShot")
    mine = shooter and shooter ~= 0 and EntityHasTag(shooter, "player_unit")
  end
  if not mine then return end
  local total = tonumber(GlobalsGetValue("wand_scanner_dmg", "0")) or 0
  GlobalsSetValue("wand_scanner_dmg", string.format("%.17g", total + damage))
end
