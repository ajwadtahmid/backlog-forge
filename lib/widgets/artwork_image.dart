import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

/// Width in pixels to decode a thumbnail at, or null to decode the full image.
/// Steam headers are 460 px wide but a list thumbnail is about 100 dp, so
/// decoding at full size wastes memory on every visible row.
int? thumbnailDecodeWidth(double? logicalWidth, double devicePixelRatio) =>
    logicalWidth == null ? null : (logicalWidth * devicePixelRatio).round();

/// Displays game artwork from a network [url], falling back to the bundled
/// no-artwork asset when the URL is null or the network request fails.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (url == null) {
      return _NoArtwork(width: width, height: height);
    }
    return CachedNetworkImage(
      imageUrl: url!,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      memCacheWidth: thumbnailDecodeWidth(
          width, MediaQuery.devicePixelRatioOf(context)),
      placeholder: (context, url) => Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      errorWidget: (context, url, error) =>
          _NoArtwork(width: width, height: height),
    );
  }
}

/// Placeholder for a game without artwork. Drawn from the theme (it used to
/// be a fixed dark image, which looked like a hole in the light theme).
class _NoArtwork extends StatelessWidget {
  const _NoArtwork({this.width, this.height});
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          'No Artwork',
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
