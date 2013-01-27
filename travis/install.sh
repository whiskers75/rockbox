while sleep 5
do printf .
done & 
export x=$! 
travis/installdeps.sh > /dev/null 2>/dev/null &
wait "$!" 
kill "$x"
echo "COMPLETED"