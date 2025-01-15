from pkg/libp2p import MultiHash

func digestBytes*(mhash: MultiHash): seq[byte] =
  ## Extract hash digestBytes
  ##

  mhash.data.buffer[mhash.dpos ..< mhash.dpos + mhash.size]
