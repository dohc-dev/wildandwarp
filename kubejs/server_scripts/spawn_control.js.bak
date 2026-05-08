// List of passive mobs you might still want to spawn in the dark (e.g., bats, owls)
const allowedOverworldSpawns = ['minecraft:bat', 'naturalist:owl'];

EntityEvents.spawned(event => {
    // Target the Overworld
    if (event.level.dimension === 'minecraft:overworld') {
        // Cancel the spawn if the entity is a monster and NOT in our allowed list
        if (event.entity.isMonster() && !allowedOverworldSpawns.includes(event.entity.type)) {
            event.cancel();
        }
    }
});