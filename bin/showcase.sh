build.sh --release 
for f in lox_examples/*lox
do
	echo $f
	odlox.exe $f
done
