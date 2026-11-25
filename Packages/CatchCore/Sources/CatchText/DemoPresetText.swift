import TransitCore

extension AppText {
    /// Demo mode's commute presets (DemoData.presets) as it starts with them: their names in this language
    public var demoPresets: [CommutePreset] {
        DemoData.presets.map { preset in
            var named = preset
            named.name = t(preset.name)
            return named
        }
    }

    /// Demo mode's presets after the language changed from `old` to this one: one still named as Demo mode named it, in the old
    /// language, takes its name in this one; one renamed in Demo mode, or added there, keeps its name
    public func demoPresetsRenamed(_ presets: [CommutePreset], from old: AppText) -> [CommutePreset] {
        let names = Dictionary(uniqueKeysWithValues: DemoData.presets.map { ($0.id, $0.name) })
        return presets.map { preset in
            guard let name = names[preset.id], preset.name == old.t(name) else { return preset }
            var renamed = preset
            renamed.name = t(name)
            return renamed
        }
    }
}
