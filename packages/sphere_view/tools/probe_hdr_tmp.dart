import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

List<double> lumaOf(img.Image im) {
  final out = List<double>.filled(im.width * im.height, 0);
  var i = 0;
  for (final p in im) { out[i++] = 0.299*p.r + 0.587*p.g + 0.114*p.b; }
  return out;
}
void main(List<String> a) {
  final pano = img.decodeImage(File('${a[0]}/stitched.png').readAsBytesSync())!;
  final ev = img.decodeImage(File('build/bundles/hdr_interior/ground_truth_ev.png').readAsBytesSync())!;
  final gt = img.decodeImage(File('build/bundles/hdr_interior/ground_truth.png').readAsBytesSync())!;
  final W = pano.width, H = pano.height;
  final p = lumaOf(pano), g = lumaOf(gt);
  double std(List<double> im, int x, int y) {
    var s = 0.0, ss = 0.0; const r = 3; const n = 49;
    for (var dy=-r; dy<=r; dy++) { final sy=(y+dy).clamp(0,H-1);
      for (var dx=-r; dx<=r; dx++) { var sx=(x+dx)%W; if(sx<0) sx+=W;
        final v = im[sy*W+sx]; s+=v; ss+=v*v; } }
    return math.sqrt(math.max(0, ss/n - (s/n)*(s/n)));
  }
  for (final region in ['window','shadow']) {
    final ps = <double>[], gs = <double>[];
    for (var y=0;y<H;y++) { for (var x=0;x<W;x++) {
      final e = ev.getPixel(x*ev.width~/W, y*ev.height~/H).rNormalized*32.0-16.0;
      final inside = region=='window' ? e>=4 : e<=-4;
      if (!inside) continue;
      ps.add(std(p,x,y)); gs.add(std(g,x,y));
    } }
    ps.sort(); gs.sort();
    String q(List<double> v)=>[10,50,90].map((k)=>'p$k ${v[(v.length-1)*k~/100].toStringAsFixed(1)}').join(' ');
    stdout.writeln('$region local std (levels)  pano: ${q(ps)}   truth: ${q(gs)}');
  }
}
