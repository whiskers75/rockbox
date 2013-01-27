{
while sleep 1
do 
printf .
done
} & 
export x=$!
sudo dash ../travis/configure.sh > /dev/null 2>/dev/null
kill "$x"
echo "COMPLETED"