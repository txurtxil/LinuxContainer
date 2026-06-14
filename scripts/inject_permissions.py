"""Inject Android permissions for Linux Container App."""
import os

manifest_path = "android/app/src/main/AndroidManifest.xml"

with open(manifest_path, "r") as f:
    content = f.read()

# Add permissions after <manifest> tag
permissions = """
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
"""

# Add network security config
res_xml_dir = "android/app/src/main/res/xml"
os.makedirs(res_xml_dir, exist_ok=True)
with open(os.path.join(res_xml_dir, "network_security_config.xml"), "w") as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
''')

print(f"✅ Permissions injected into {manifest_path}")
