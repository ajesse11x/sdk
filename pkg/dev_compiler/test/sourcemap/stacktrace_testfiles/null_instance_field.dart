// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

main() {
  /*1:main*/ test(Class());
}

test(c) {
  /*ddc.2:test*/ c.field. /*ddk.2:test*/ method();
}

class Class {
  var field;
}
