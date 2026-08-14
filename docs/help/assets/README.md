# Help and wizard assets

This directory stores source screenshots and images used by the portal Help Docs and wizard guidance.

These files are source assets. They are copied into the generated portal help output during the help-doc build.

## Source location

```text
docs/help/assets/
```

## Generated location

The build script copies this directory to:

```text
frontend/help/assets/
```

The live portal serves the copied files from:

```text
/help/assets/<filename>
```

## Referencing assets from help markdown

Reference images from markdown files under `docs/help/` like this:

```markdown
![Description](assets/<image-file>.png)
```

## Do not edit generated copies

Do not manually edit generated copies under:

```text
frontend/help/assets/
```

or an installed runtime copy such as:

```text
/opt/otp-relay/frontend/help/assets/
```

Generated help assets should always come from the source files in this directory.
