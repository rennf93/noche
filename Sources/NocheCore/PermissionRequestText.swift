/// The line the permission prompt shows under the site: what the page asks for.
public enum PermissionRequestText {
    public static func text(camera: Bool, microphone: Bool, geolocation: Bool, notifications: Bool, screen: Bool) -> String {
        let use = [(camera, "camera"), (microphone, "microphone"), (geolocation, "location")].filter(\.0).map(\.1)
        let actions = (screen ? ["share your screen"] : []) + (use.isEmpty ? [] : ["use your " + use.joined(separator: " and ")])
        if !actions.isEmpty { return "wants to " + actions.joined(separator: " and ") }
        return notifications ? "wants to show notifications" : "wants to use a browser feature"
    }
}
