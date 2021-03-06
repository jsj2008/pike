#pike __REAL_VERSION__
inherit Tools.Shoot.Test;

constant name="Matrix multiplication";

int size = 100;

array(array(float)) mkmatrix(int rows, int cols) 
{
   return map(enumerate(rows*cols,1,0),
	      lambda(int f, float den)
	      {
		if (f & 1)
		  return -((float)f)/den;
		return ((float)f)/den;
	      }, (float)rows*cols)/cols;
}

void test(int n)
{
    Math.Matrix m1 = Math.Matrix(mkmatrix(size, size));
    Math.Matrix m2 = Math.Matrix(mkmatrix(size, size));
    while (n--) m1=m1*m2;
    array q = (array(array(int)))(array)m1;
}

void perform()
{
   test(100);
}
