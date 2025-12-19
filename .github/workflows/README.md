# GitHub Actions Workflows

This directory contains GitHub Actions workflows for CI/CD.

## Docker Build and Push

### Workflows

1. **`docker-build-push.yml`** - Builds and pushes Docker images to GitHub Container Registry (ghcr.io)
   - Triggers on pushes to `main`/`master` branches
   - Triggers on version tags (e.g., `v1.0.0`)
   - Pushes images to `ghcr.io/<owner>/<repo>`

2. **`docker-build-pr.yml`** - Builds Docker images for pull requests (no push)
   - Triggers on pull requests to `main`/`master`
   - Only builds the image (doesn't push) to verify the Dockerfile works

### Authentication

The workflow uses GitHub's built-in `GITHUB_TOKEN` for authentication. No additional secrets are required!

The workflow automatically:
- Uses the repository owner/name for the image path
- Authenticates using `GITHUB_TOKEN` (automatically provided by GitHub Actions)
- Requires `packages: write` permission (configured in the workflow)

### Image Tagging

Images are automatically tagged based on:
- **Branch name**: `ghcr.io/<owner>/<repo>:main`
- **Git SHA**: `ghcr.io/<owner>/<repo>:main-abc1234`
- **Version tags**: `ghcr.io/<owner>/<repo>:v1.0.0`, `ghcr.io/<owner>/<repo>:1.0`, `ghcr.io/<owner>/<repo>:1`
- **Latest**: `ghcr.io/<owner>/<repo>:latest` (only for default branch)

### Pulling Images

To pull the image:

```bash
# Login to ghcr.io (if pulling private images)
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Pull the image
docker pull ghcr.io/<owner>/<repo>:latest
```

### Making Images Public

By default, images pushed to GitHub Container Registry are private. To make them public:

1. Go to your GitHub repository
2. Click on "Packages" (right sidebar)
3. Click on your package
4. Click "Package settings"
5. Scroll down to "Danger Zone" and click "Change visibility"
6. Select "Public"

### Customization

The image name is automatically derived from the repository name (`${{ github.repository }}`). To customize, edit the `IMAGE_NAME` environment variable in `.github/workflows/docker-build-push.yml`:

```yaml
env:
  IMAGE_NAME: your-custom-name
```


