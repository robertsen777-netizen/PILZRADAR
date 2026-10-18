from pathlib import Path
p=Path('android/app/src/main/AndroidManifest.xml')
s=p.read_text()
perms='''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.CALL_PHONE"/>'''
s=s.replace('<application',perms+'\n    <application',1)
p.write_text(s)
g=Path('android/app/build.gradle.kts')
if g.exists():
 t=g.read_text().replace('minSdk = flutter.minSdkVersion','minSdk = 23')
 g.write_text(t)
