import Foundation

/// Short, distinct display names for Apple's catalogue. Apple's accessibility labels are useful
/// prose but poor library titles: many are repeated, four are blank, and several run to ten words.
/// Shot ids are stable across manifest revisions, so names can improve without becoming storage
/// identifiers or breaking favorites/downloads.
enum CatalogNames {
    static func title(label: String, shotID: String) -> String {
        curated[shotID] ?? compact(label)
    }

    private static func compact(_ raw: String) -> String {
        let filler: Set<String> = ["the", "and", "a", "of", "in"]
        var words = raw.replacingOccurrences(of: ",", with: "")
            .split(separator: " ")
            .map(String.init)
            .filter { !filler.contains($0.lowercased()) }
        if words.isEmpty { words = ["Untitled", "Aerial"] }
        if words.count == 1 { words.append(words[0] == "Aerial" ? "View" : "Aerial") }
        return words.prefix(4).joined(separator: " ")
    }

    private static let curated: [String: String] = [
        // Earth
        "A001_C001_120530": "Atlantic Europe",
        "A001_C004_1207W5": "Africa Alps",
        "A009_C001_10181A": "Sahara Italy",
        "A050_C004_1027V8": "Nile Delta",
        "A083_C002_1130KZ": "Iran Afghanistan",
        "A103_C002_0205DG": "Africa Middle East",
        "A105_C002": "Caribbean Cuba",
        "A108_C001": "Caribbean Bahamas",
        "A114_C001": "California Baja",
        "A351_C001_1213SK": "Africa North Asia",
        "GMT026_363A_103NC_E1027_KOREA_JAPAN_NIGHT": "Korea Japan Night",
        "GMT060_117NC_363D_1034_AUSTRALIA": "Australia Flyover",
        "GMT110_112NC_364D_1054_AURORA_ANTARCTICA": "Antarctic Aurora",
        "GMT306_139NC_139J_3066_CALI_TO_VEGAS": "California Vegas",
        "GMT329_113NC_396B_1105_ITALY_TO_ASIA": "Italy Asia",
        "GMT329_117NC_401C_1037_IRELAND_TO_ASIA": "Ireland Asia",

        // Underwater
        "A003_C014": "Alaska Moon Jellies",
        "A004_C012": "Alaska Jelly Drift",
        "A014_C023": "Bigeye Jacks",
        "BO_A014_C008": "Bumphead Parrotfish",
        "BO_A018_C029": "Barracuda School",
        "KP_A010_C002": "Cape Kelp Forest",
        "PA_A001_C007": "Palau Jelly Swarm",
        "PA_A002_C009": "Palau Golden Jellies",
        "PA_A010_C007": "Palau Jelly Drift",

        // San Francisco
        "A006_C003": "Golden Gate Bay",
        "A007_C017": "Coit Tower Downtown",
        "A008_C007": "Marin Golden Gate",
        "A012_C014": "Embarcadero Market Street",
        "A013_C004": "Downtown Market Street",
        "A013_C012": "Golden Gate Crossing",
        "A015_C018": "Bay Bridge Downtown",

        // China
        "C001_C005": "Mutianyu Great Wall",
        "C003_C003": "Great Wall Ridge",
        "C004_C003": "Great Wall Valley",
        "CH_C002_C005": "Longji Rice Terraces",
        "CH_C007_C004": "Wulingyuan Peaks",
        "CH_C007_C011": "Wulingyuan Valley",
        "GMT329_2_113NC_396B_1105": "Shanghai Approach",

        // Dubai and Liwa
        "DB_D001_C001": "Dubai Marina Coast",
        "DB_D001_C005": "Dubai Marina Towers",
        "DB_D002_C003": "Downtown Dubai",
        "DB_D008_C010": "Sheikh Zayed Road",
        "DB_D011_C010": "Burj Khalifa Coast",
        "LW_L001_C003": "Liwa Oasis Dunes",
        "LW_L001_C006": "Liwa Desert Ridges",

        // Grand Canyon
        "G007_C004": "Colorado River Canyon",
        "G008_C015_0106MB": "Burnt Canyon",
        "G009_C003_010678": "Grand Canyon Plateau",
        "G009_C014_0106B9": "Grand Canyon Passage",
        "G010_C026_0107KE": "Colorado River Bend",

        // Greenland
        "GL_G002_C002": "Ilulissat Icefjord",
        "GL_G004_C010": "Nuussuaq Peninsula",
        "GL_G010_C006": "Icefjord Passage",

        // Hawaii
        "H004_C007": "Puu O Umi",
        "H004_C009": "Kohala Forest Ridge",
        "H005_C012": "Waimanu Valley",
        "H007_C003": "Laupahoehoe Nui",
        "H012_C009_0": "Kohala Coastline",

        // Hong Kong
        "HK_B005_C011": "Victoria Harbour Central",
        "HK_H004_C008": "Victoria Harbour Island",
        "HK_H004_C010": "Victoria Peak Harbour",
        "HK_H004_C013": "Wan Chai Central",

        // Iceland
        "I003_C004": "Langisjor Lake",
        "I003_C005": "Iceland Highlands",
        "I003_C008": "Tungnaa Highlands",
        "I003_C011": "Jokulgilskvisl River",
        "I003_C015": "Jokulgil Canyon",
        "I004_C014": "Landmannalaugar Ridges",
        "I005_C008": "Myrdalsjokull Glacier",

        // London
        "L004_C011": "Thames London Eye",
        "L007_C007": "Buckingham Palace Thames",
        "L010_C006": "Tower Bridge Thames",
        "L012_C002": "Westminster Thames",

        // Los Angeles
        "LA_A005_C009": "Los Angeles Freeway",
        "LA_A006_C004": "Hollywood Sign",
        "LA_A006_C008": "LAX Approach",
        "LA_A008_C004": "Santa Monica Pier",
        "LA_A009_C009": "Griffith Observatory",
        "LA_A011_C003": "Downtown Los Angeles",

        // New York
        "N003_C006": "Central Park Midtown",
        "N008_C003": "Lower Manhattan",
        "N008_C009": "Central Park Skyline",
        "N013_C004": "Times Square",

        // Patagonia
        "P001_C005_11059D": "Cuernos del Paine",
        "P005_C002_1109E1": "Nordenskjold Shore",
        "P006_C002_11106T": "Nordenskjold Lake",
        "P007_C027": "Torres del Paine",

        // Scotland
        "S003_C020": "Isle Skye Coast",
        "S005_C015": "Loch Moidart",
        "S006_C007": "Castle Tioram",

        // Yosemite
        "Y002_C013_0226": "Half Dome Approach",
        "Y003_C009_027": "Merced Peak",
        "Y004_C015_0227PD": "Half Dome Nevada Fall",
        "Y005_C003_0228SC": "Yosemite Falls",
        "Y009_C015_0304I": "Tuolumne Meadows",
        "Y011_C001_0305": "Yosemite Valley",
        "Y011_C008_030584": "Matthes Crest",

        // California, Oregon, Utah
        "M005_C017_F01": "Olympia Bar",
        "M007_C007_F01": "Monument Valley Crossing",
        "M010_C005_F01": "Cathedral Canyon",
        "M010_C009_F01": "Cascade Canyon Twilight",
        "M012_C023_S04": "Factory Butte",
        "M012_C065_S04": "Monument Valley Buttes",
        "M013_C012_F01": "Coal Mine Canyon",
        "R004_C012_F01": "Secret Beach Bridges",
        "R006_C013_S05": "Oregon China Beach",
        "R010_C003_F01": "Del Norte Redwoods",
        "R013_C039_F01": "Trinity River Redwoods",
        "S005_C013_F01": "Sonoma Northbound",
        "S009_C018_F01": "Sonoma Redwoods",
        "S011_C003_F01": "Sonoma Valley",
        "S013_C001_F01": "California Coast",
        "W014_C018_F01": "Temblor Wildflowers",
        "W015_C006_F01": "California Wildflower Fields",
        "W015_C010_F01": "Carrizo Wildflowers",
        "W010_C003_F01": "Cazadero Forest",

        "SE_A016_C009": "Cape Fur Seals",

        // India and Tahiti
        "ANN0010": "Ghansali Terraces",
        "ANN0020": "Garhwal Himalayas",
        "ANN0040": "Munnar Tea Gardens",
        "ANN0070": "Upper Sholayar Reservoir",
        "ANN0090": "Garhwal Himalayas Day",
        "ANN0100": "Munnar Gardens Day",
        "ANN0110": "Ganges River",
        "ANN0120": "Himalayan Peaks",
        "ANN0130": "Munnar Garden Mist",
        "TH_803_A001_8": "Tahiti Shore Break",
        "TH_804_A001_8": "Tahiti Rolling Waves",
    ]
}
