import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The Asite mark from the prototype: a red rounded square holding a white
/// outlined cube with an arrow through it.
///
/// ASSUMED — drawn in code rather than shipped as an asset, because no vector
/// logo file came with the prototype. Swap this for the official SVG or PNG
/// when brand supplies one; nothing else changes.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Asite',
      child: Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          color: AppColors.brandMark,
          borderRadius: BorderRadius.circular(size * 0.22),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.login_rounded,
          size: size * 0.58,
          color: Colors.white,
        ),
      ),
    );
  }
}
