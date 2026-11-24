import os
import zipfile
import shutil

def build_rbz():
    src_dir = os.path.join(os.path.dirname(__file__), 'src')
    dist_dir = os.path.join(os.path.dirname(__file__), 'dist')
    os.makedirs(dist_dir, exist_ok=True)
    
    rbz_path = os.path.join(dist_dir, 'quick_draft.rbz')

    with zipfile.ZipFile(rbz_path, 'w', zipfile.ZIP_DEFLATED) as rbz:
        for root, _, files in os.walk(src_dir):
            for file in files:
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, src_dir)
                rbz.write(full_path, rel_path)

    print(f"Built extension package: {rbz_path}")

    # Auto-deploy to SketchUp 2020 plugins folder if present
    appdata = os.environ.get('APPDATA')
    if appdata:
        su_plugins = os.path.join(appdata, 'SketchUp', 'SketchUp 2020', 'SketchUp', 'Plugins')
        if os.path.isdir(su_plugins):
            dest_rb = os.path.join(su_plugins, 'quick_draft.rb')
            dest_dir = os.path.join(su_plugins, 'quick_draft')
            shutil.copy2(os.path.join(src_dir, 'quick_draft.rb'), dest_rb)
            if os.path.exists(dest_dir):
                shutil.rmtree(dest_dir)
            shutil.copytree(os.path.join(src_dir, 'quick_draft'), dest_dir)
            print(f"Auto-deployed live to: {su_plugins}")

if __name__ == '__main__':
    build_rbz()
