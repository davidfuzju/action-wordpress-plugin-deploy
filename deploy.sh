#!/bin/bash

# Note that this does not use pipefail
# because if the grep later doesn't match any deleted files,
# which is likely to be the case the majority of the time,
# it does not exit with 0, as we are interested in the final exit.
set -eo

if $INPUT_DRY_RUN; then
	echo "ℹ︎ Dry run: No files will be committed to Subversion."
fi

# Allow some ENV variables to be customized
if [[ -z "$SLUG" ]]; then
	SLUG=${GITHUB_REPOSITORY#*/}
fi
echo "ℹ︎ SLUG is $SLUG"

# Allow setting custom version number in advanced workflows
if [[ -z "$VERSION" ]]; then
	VERSION="${GITHUB_REF#refs/tags/}"
	VERSION="${VERSION#v}"
fi
echo "ℹ︎ VERSION is $VERSION"

if [[ -z "$ASSETS_DIR" ]]; then
	ASSETS_DIR=".wordpress-org"
fi
echo "ℹ︎ ASSETS_DIR is $ASSETS_DIR"

if [[ -z "$BUILD_DIR" ]] || [[ $BUILD_DIR == "./" ]]; then
	BUILD_DIR=false
elif [[ $BUILD_DIR == ./* ]]; then 
	BUILD_DIR=${BUILD_DIR:2}
fi

if [[ "$BUILD_DIR" != false ]]; then
	if [[ $BUILD_DIR != /* ]]; then 
		BUILD_DIR="${GITHUB_WORKSPACE%/}/${BUILD_DIR%/}"
	fi
	echo "ℹ︎ BUILD_DIR is $BUILD_DIR"
fi

SVN_DIR="${HOME}/svn-${SLUG}"

# Checkout SVN repository.
echo "➤ Checking out directory exists..."

if [ ! -d "$SVN_DIR" ]; then
  mkdir "$SVN_DIR"
  echo "Directory '$SVN_DIR' created successfully"
else
  echo "Directory '$SVN_DIR' exists already"
fi

cd "$SVN_DIR"

generate_zip() {
  if $INPUT_GENERATE_ZIP; then
    echo "Generating zip file..."

    # use a symbolic link so the directory in the zip matches the slug
    ln -s "${SVN_DIR}/trunk" "${SVN_DIR}/${SLUG}"
    zip -r "${GITHUB_WORKSPACE}/${SLUG}.zip" "$SLUG"
    unlink "${SVN_DIR}/${SLUG}"

    echo "zip-path=${GITHUB_WORKSPACE}/${SLUG}.zip" >> "${GITHUB_OUTPUT}"
    echo "✓ Zip file generated!"
  fi
}

# Bail early if the plugin version is already published.
if [[ -d "tags/$VERSION" ]]; then
	echo "ℹ︎ Version $VERSION of plugin $SLUG was already published";

	generate_zip

	exit
fi

if [[ "$BUILD_DIR" = false ]]; then
	echo "➤ Copying files..."
	if [[ -e "$GITHUB_WORKSPACE/.distignore" ]]; then
		echo "ℹ︎ Using .distignore"
		# Copy from current branch to /trunk, excluding dotorg assets
		# The --delete flag will delete anything in destination that no longer exists in source
		rsync -rc --exclude-from="$GITHUB_WORKSPACE/.distignore" "$GITHUB_WORKSPACE/" trunk/ --delete --delete-excluded
	else
		echo "ℹ︎ Using .gitattributes"

		cd "$GITHUB_WORKSPACE"

		# "Export" a cleaned copy to a temp directory
		TMP_DIR="${HOME}/archivetmp"
		mkdir "$TMP_DIR"

		# Workaround for: detected dubious ownership in repository at '/github/workspace' issue.
		# see: https://github.com/10up/action-wordpress-plugin-deploy/issues/116
		# Mark github workspace as safe directory.
		git config --global --add safe.directory "$GITHUB_WORKSPACE"

		git config --global user.email "10upbot+github@10up.com"
		git config --global user.name "10upbot on GitHub"

		# Ensure git archive will pick up any changed files in the directory try.
		test $(git ls-files --deleted) && git rm $(git ls-files --deleted)
		if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
			git add .
			git commit -m "Include build step changes"
		fi

		# If there's no .gitattributes file, write a default one into place
		if [[ ! -e "$GITHUB_WORKSPACE/.gitattributes" ]]; then
			cat > "$GITHUB_WORKSPACE/.gitattributes" <<-EOL
			/$ASSETS_DIR export-ignore
			/.gitattributes export-ignore
			/.gitignore export-ignore
			/.github export-ignore
			EOL

			# Ensure we are in the $GITHUB_WORKSPACE directory, just in case
			# The .gitattributes file has to be committed to be used
			# Just don't push it to the origin repo :)
			git add .gitattributes && git commit -m "Add .gitattributes file"
		fi

		# This will exclude everything in the .gitattributes file with the export-ignore flag
		git archive HEAD | tar x --directory="$TMP_DIR"

		cd "$SVN_DIR"

		# Copy from clean copy to /trunk, excluding dotorg assets
		# The --delete flag will delete anything in destination that no longer exists in source
		rsync -rc "$TMP_DIR/" trunk/ --delete --delete-excluded
	fi
else
	echo "ℹ︎ Copying files from build directory..."
	rsync -rc "$BUILD_DIR/" trunk/ --delete --delete-excluded
fi

# Copy dotorg assets to /assets
if [[ -d "$GITHUB_WORKSPACE/$ASSETS_DIR/" ]]; then
	rsync -rc "$GITHUB_WORKSPACE/$ASSETS_DIR/" assets/ --delete
else
	echo "ℹ︎ No assets directory found; skipping asset copy"
fi

generate_zip

echo "✓ Plugin deployed!"
