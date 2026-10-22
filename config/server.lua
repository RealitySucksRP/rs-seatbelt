return {
    framework = 'auto', -- auto, qbox, qbcore, esx
    inventory = 'auto', -- auto, ox, qb, esx (native ESX consumes one harness per equip)
    storage = 'json', -- json or sql; sql requires oxmysql and sql/install.sql
    personalMode = 'full', -- server: owner only; alignment: personal fit; full: personal assets + fit
    adminAce = 'rs-seatbelt.admin',
    harnessItem = 'harness',
    harnessWear = 5,
    -- Optional restrictions for personal assets. Empty lists allow valid asset names.
    allowedModels = {},
    allowedDictionaries = {},
    saveCooldownSeconds = 2,
}
