/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, and Ari Harju

    This file is part of GPUQT.

    GPUQT is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    GPUQT is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with GPUQT.  If not, see <http://www.gnu.org/licenses/>.
*/


#include "sigma.h"
#include "vector.h"
#include "hamiltonian.h"
#include "model.h"
#include <iostream>
#include <fstream>



// Find the Chebyshev moments defined in Eqs. (32-34) in [Comput. Phys. Commun.185, 28 (2014)].
// See Algorithm 5 in [Comput. Phys. Commun.185, 28 (2014)].
void find_moments_chebyshev(Model& model, Hamiltonian& H, Vector& state_left, Vector& state_right, Vector& output)
{
    int grid_size = (model.number_of_atoms - 1) / BLOCK_SIZE + 1;

    Vector state_0(state_right), state_1(model), state_2(model); 
    Vector inner_product_1(grid_size * model.number_of_moments, model);
	
    // Tr[T_0(H)] = <left|right>
    int offset = 0 * grid_size;
    state_0.inner_product_1(state_left, inner_product_1, offset);
	
    // Tr[T_1(H)] = <left|H|right>
    H.apply(state_0, state_1);
    offset = 1 * grid_size;
    state_1.inner_product_1(state_left, inner_product_1, offset);

    // Tr[T_m(H)] (m >= 2)
    for (int m = 2; m < model.number_of_moments; ++m)
    {    
        H.kernel_polynomial(state_0, state_1, state_2); 
        offset = m * grid_size;
        state_2.inner_product_1(state_left, inner_product_1, offset);
        // permute the pointers; do not need to copy the data
        state_0.swap(state_1);
        state_1.swap(state_2);
    } 
    inner_product_1.inner_product_2(output);
}



// This is the Jackson kernel
// TODO: other kernels
void apply_damping(Model& model, real *inner_product_real, real *inner_product_imag)
{
    for (int k = 0; k < model.number_of_moments; ++k)
    {  
        real factor = 1.0 / (model.number_of_moments + 1);
        real damping = (1 - k * factor) * cos(k * PI * factor)
                     + sin(k * PI * factor) * factor / tan(PI * factor);    
        inner_product_real[k] *= damping;
        inner_product_imag[k] *= damping;
    }
}



// Do the summation in Eqs. (29-31) in [Comput. Phys. Commun.185, 28 (2014)]
void perform_chebyshev_summation
(
    Model& model,
    real *inner_product_real,
    real *inner_product_imag,
    real *correlation_function
)
{   
    for (int step1 = 0; step1 < model.number_of_energy_points; ++step1)
    {
        real energy_scaled = model.energy[step1] / model.energy_max;
        real chebyshev_0 = 1.0;
        real chebyshev_1 = energy_scaled;
        real chebyshev_2;
        real temp = inner_product_real[1] * chebyshev_1;
        for (int step2 = 2; step2 < model.number_of_moments; ++step2)
        {
            chebyshev_2 = 2.0 * energy_scaled * chebyshev_1 - chebyshev_0;
            chebyshev_0 = chebyshev_1;
            chebyshev_1 = chebyshev_2;
            temp += inner_product_real[step2] * chebyshev_2;             
        }
        temp *= 2.0;
        temp += inner_product_real[0];
        temp *= 2.0 / (PI * model.volume); 
        temp /= sqrt(1.0 - energy_scaled * energy_scaled);
        correlation_function[step1] = temp / model.energy_max; 
    }
}



// Calculate:
// U(+t) |state> when direction = +1;
// U(-t) |state> when direction = -1. 
// See Eq. (36) and Algorithm 6 in [Comput. Phys. Commun.185, 28 (2014)].
void evolve(Model& model, int direction, real time_step_scaled, Hamiltonian& H, Vector& state_in)
{
    Vector state_0(state_in), state_1(model), state_2(model);
    // T_0(H) |psi> = |psi>
	// Copied in construction

    // T_1(H) |psi> = H |psi> 
    H.apply(state_in, state_1);

    // |final_state> = c_0 * T_0(H) |psi> + c_1 * T_1(H) |psi>
    real bessel_0 = j0(time_step_scaled);
    real bessel_1 = 2.0 * j1(time_step_scaled);
    
    H.chebyshev_01(state_0, state_1, state_in, bessel_0, bessel_1, direction);

    for (int m = 2; m < 1000000; ++m)
    {
        real bessel_m = jn(m, time_step_scaled);
        if (bessel_m < 1.0e-15 && bessel_m > -1.0e-15) { break; }
        bessel_m *= 2.0;
        int label;
        int m_mod_4 = m % 4;
        if (m_mod_4 == 0)                             { label = 1; }    
        else if (m_mod_4 == 2)                        { label = 2; }        
        else if ((m_mod_4 == 1 && direction ==  1) || 
                 (m_mod_4 == 3 && direction == -1))   { label = 3; }       
        else                                          { label = 4; }
        H.chebyshev_2(state_0, state_1, state_2, state_in, bessel_m, label);
        // permute the pointers; do not need to copy the data
        state_0.swap(state_1);
        state_1.swap(state_2); 
    } 
}


// Calculate: 
// [X, U(+t)] |state> when direction = +1;
// [U(-t), X] |state> when direction = -1.
// See Eq. (37) and Algorithm 7 in [Comput. Phys. Commun.185, 28 (2014)].
void evolvex(Model& model, int direction, real time_step_scaled, Hamiltonian& H, Vector& state_in)
{
    Vector state_0(state_in), state_0x(model);
    Vector state_1(model), state_1x(model);    
    Vector state_2(model), state_2x(model);    

    // T_0(H) |psi> = |psi>
	// This is done in constructor of state_0

    // [X, T_0(H)] |psi> = 0
    // This is done in the initialization of state_0x

    // T_1(H) |psi> = H |psi> 
    H.apply(state_in, state_1);
    
    // [X, T_1(H)] |psi> = J |psi> 
    H.apply_commutator(state_in, state_1x);

    // |final_state> = c_1 * [X, T_1(H)] |psi>
    real bessel_1 = 2.0 * j1(time_step_scaled);
    H.chebyshev_1x(state_1x, state_in, bessel_1);

    for (int m = 2; m <= 1000000; ++m)
    { 
        real bessel_m = jn(m, time_step_scaled);
        if (bessel_m < 1.0e-15 && bessel_m > -1.0e-15) { break; }
        bessel_m *= 2.0;        
        int label;
        int m_mod_4 = m % 4;
        if (m_mod_4 == 1)                             { label = 3; }    
        else if (m_mod_4 == 3)                        { label = 4; }        
        else if ((m_mod_4 == 0 && direction ==  1) || 
                 (m_mod_4 == 2 && direction == -1))   { label = 1; }       
        else                                          { label = 2; }
            H.chebyshev_2x(state_0, state_0x, state_1, state_1x, state_2, state_2x, state_in, bessel_m, label);

        // Permute the pointers; do not need to copy the data
        state_0.swap(state_1);
        state_1.swap(state_2);
        state_0x.swap(state_1x);
        state_1x.swap(state_2x);
    } 
}


// calculate the DOS as a function of Fermi energy
// See Algorithm 1 in [Comput. Phys. Commun.185, 28 (2014)].
void find_dos(Model& model, Hamiltonian& H, Vector& random_state)
{
    Vector inner_product_2(model.number_of_moments, model);

    real *dos;
    real *inner_product_real;
    real *inner_product_imag;

    dos = new real[model.number_of_energy_points];
    inner_product_real = new real[model.number_of_moments];
    inner_product_imag = new real[model.number_of_moments]; 
    
    find_moments_chebyshev(model, H, random_state, random_state, inner_product_2);
    inner_product_2.copy_to_host(inner_product_real, inner_product_imag);

    apply_damping(model, inner_product_real, inner_product_imag);
    perform_chebyshev_summation
    (model, inner_product_real, inner_product_imag, dos);

    
    std::ofstream output(model.input_dir + "/dos.out", std::ios::app);

    if (!output.is_open())
    {
        std::cout <<"Error: cannot open " + model.input_dir + "/dos.out" << std::endl;
        exit(1);
    }

    for (int n = 0; n < model.number_of_energy_points; ++n)
    {
        output << dos[n] << " ";
    }
    output << std::endl;
    output.close();

    delete[] inner_product_real;
    delete[] inner_product_imag;
    delete[] dos;
}


// calculate the VAC as a function of correlation time and Fermi energy
// See Algorithm 2 in [Comput. Phys. Commun.185, 28 (2014)].
void find_vac(Model& model, Hamiltonian& H, Vector& random_state)
{
    Vector state_left(random_state);
    Vector state_left_copy(model);
    Vector state_right(random_state);
    Vector inner_product_2(model.number_of_moments, model);
	
    real *inner_product_real; 
    real *inner_product_imag;
    real *vac;
    real *vac_total;
    
    vac = new real[model.number_of_energy_points];
    vac_total = new real[model.number_of_energy_points * model.number_of_steps_correlation];
    inner_product_real = new real[model.number_of_moments];
    inner_product_imag = new real[model.number_of_moments];

    H.apply_current(state_left, state_right);

    for (int m = 0; m < model.number_of_steps_correlation; ++m)
    {
        H.apply_current(state_left, state_left_copy);		
        find_moments_chebyshev(model, H, state_right, state_left_copy, inner_product_2);
        inner_product_2.copy_to_host(inner_product_real, inner_product_imag);

        apply_damping(model, inner_product_real, inner_product_imag);
        perform_chebyshev_summation(model, inner_product_real, inner_product_imag, vac);                     

        for (int n = 0; n < model.number_of_energy_points; ++n)
        {
            vac_total[m * model.number_of_energy_points + n] = vac[n];
        }

        if (m < model.number_of_steps_correlation - 1)
        {
            real time_step_scaled = model.time_step[m] * model.energy_max;
            evolve(model, -1, time_step_scaled, H, state_left);
            evolve(model, -1, time_step_scaled, H, state_right);
        }
    }

    std::ofstream output(model.input_dir + "/vac.out", std::ios::app);
    if (!output.is_open())
    {
        std::cout <<"Error: cannot open " + model.input_dir + "/vac.out" 
                  << std::endl;
        exit(1);
    }
    for (int m = 0; m < model.number_of_steps_correlation; ++m)
    {
        for (int n = 0; n < model.number_of_energy_points; ++n)
        {
            output << vac_total[m * model.number_of_energy_points + n] << " ";
        }
        output << std::endl;
    }
    output.close();

    delete[] inner_product_real;
    delete[] inner_product_imag;
    delete[] vac;
    delete[] vac_total;
}


// calculate the MSD as a function of correlation time and Fermi energy
// See Algorithm 3 in [Comput. Phys. Commun.185, 28 (2014)].
void find_msd(Model& model, Hamiltonian& H, Vector& random_state)
{
    Vector state(random_state);
    Vector state_x(random_state);	
    Vector state_copy(model);
    Vector inner_product_2(model.number_of_moments, model);

    real *inner_product_real; 
    real *inner_product_imag;
    real *msd;
    real *msd_total;

    msd = new real[model.number_of_energy_points];
    msd_total = new real[model.number_of_energy_points * model.number_of_steps_correlation];
    inner_product_real = new real[model.number_of_moments];
    inner_product_imag = new real[model.number_of_moments];
  
    real time_step_scaled = model.time_step[0] * model.energy_max;
    evolve(model, 1, time_step_scaled, H, state);
    evolvex(model, 1, time_step_scaled, H, state_x);

    for (int m = 0; m < model.number_of_steps_correlation; ++m)
    {
        find_moments_chebyshev(model, H, state_x, state_x, inner_product_2);
        inner_product_2.copy_to_host(inner_product_real, inner_product_imag);

        apply_damping(model, inner_product_real, inner_product_imag);
        perform_chebyshev_summation
        (model, inner_product_real, inner_product_imag, msd);

        for (int n = 0; n < model.number_of_energy_points; ++n)
        {
            msd_total[m * model.number_of_energy_points + n] = msd[n];
        }

        if (m < model.number_of_steps_correlation - 1)
        {
            time_step_scaled = model.time_step[m + 1] * model.energy_max;
              
            // update [X, U^m] |phi> to [X, U^(m+1)] |phi>
            state_copy.copy(state);
	
            evolvex(model, 1, time_step_scaled, H, state_copy);
            evolve(model, 1, time_step_scaled, H, state_x);

            state_x.add(state_copy);        
			
            // update U^m |phi> to U^(m+1) |phi>
            evolve(model, 1, time_step_scaled, H, state);

        }   
    }
	
    std::ofstream output(model.input_dir + "/msd.out", std::ios::app);
    if (!output.is_open())
    {
        std::cout << "Error: cannot open " + model.input_dir + "/msd.out" 
                  << std::endl;
        exit(1);
    }

    for (int m = 0; m < model.number_of_steps_correlation; ++m)
    {
        for (int n = 0; n < model.number_of_energy_points; ++n)
        {
            output << msd_total[m * model.number_of_energy_points + n] << " ";
        }
        output << std::endl;
    }
    output.close();    
    
    delete[] inner_product_real;
    delete[] inner_product_imag;
    delete[] msd;
    delete[] msd_total;
}



