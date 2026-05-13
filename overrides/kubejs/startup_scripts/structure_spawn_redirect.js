// This is a conceptual example; 1.21.1 NeoForge KubeJS 
// allows modifying JSON files in the config folder.
const configPath = 'config/structurify.json';
let config = JsonIO.read(configPath);

if (config) {
    config.structure_namespaces.forEach(namespace => {
        // We only care about the desert for this example
        // You would expand this for your 20 biomes
        const desertVariants = [
            "still_life:desert",
            "still_life:desert_dunes",
            "still_life:desert_scrub"
        ];

        // This loops through EVERY structure Structurify found
        namespace.structures.forEach(structure => {
            // Check if 'minecraft:desert' is in its current whitelist
            if (structure.biomes && structure.biomes.includes("minecraft:desert")) {
                // Add your modded biomes to its specific Structurify list
                desertVariants.forEach(v => {
                    if (!structure.biomes.includes(v)) {
                        structure.biomes.push(v);
                    }
                });
            }
        });
    });
    JsonIO.write(configPath, config);
}