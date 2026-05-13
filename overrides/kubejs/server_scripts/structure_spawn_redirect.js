ServerEvents.tags('worldgen/biome', event => {
    // 1. Create your "Replacer" Biome Tags
    // This groups your Still Life biomes so we can add them to structures in one go.
    const STILL_LIFE_DESERTS = [
        'still_life:desert', 
        'still_life:desert_dunes', 
        'still_life:desert_scrub',
        'still_life:luxuriant_desert'
    ]
    
    const STILL_LIFE_PLAINS = [
        'still_life:prairie', 
        'still_life:meadow', 
        'still_life:grassland'
    ]

    // 2. Target the "Universal" Biome Tags
    // Most structures (Vanilla & Modded) check these category tags first.
    // By adding to these, you catch structures even if they don't have the biome name in their ID.
    event.add('minecraft:is_desert', STILL_LIFE_DESERTS)
    event.add('c:is_desert', STILL_LIFE_DESERTS)
    
    event.add('minecraft:is_plains', STILL_LIFE_PLAINS)
    event.add('c:is_plains', STILL_LIFE_PLAINS)

    // 3. Target Specific Vanilla Structure Tags
    // This fixes the 150+ structures that might be hard-coded to vanilla locations.
    const VANILLA_STRUCTURE_TAGS = [
        'minecraft:has_structure/village_desert',
        'minecraft:has_structure/desert_pyramid',
        'minecraft:has_structure/pillager_outpost',
        'minecraft:has_structure/village_plains',
        'minecraft:has_structure/ancient_city',

    ]

    VANILLA_STRUCTURE_TAGS.forEach(tag => {
        if (tag.contains('desert')) {
            event.add(tag, STILL_LIFE_DESERTS)
        } else if (tag.contains('plains')) {
            event.add(tag, STILL_LIFE_PLAINS)
        }
    })
})